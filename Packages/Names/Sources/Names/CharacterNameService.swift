import Core
import CryptoKit
import Dictionary
import Foundation
import GRDB

/// A series of ours to find the cast of: a Kavita series (Yomu) or a Jellyfin show (Miru).
public struct NamedSeries: Equatable, Sendable {
    /// "kavita:<server>:<id>", "jellyfin:<server>:<id>".
    public var key: String
    public var title: String
    /// Its other titles (Kavita's localized name, Jellyfin's original title).
    public var otherTitles: [String]
    public var type: AniListMediaType
    /// For MangaBaka (manga and light novels); nil for shows.
    public var kind: MangaBakaClient.Kind?
    /// What the server knows: Kavita's `aniListId`/`malId`, Jellyfin's provider ids.
    public var aniListId: Int?
    public var malId: Int?

    public init(key: String, title: String, otherTitles: [String] = [], type: AniListMediaType, kind: MangaBakaClient.Kind? = nil,
                aniListId: Int? = nil, malId: Int? = nil) {
        self.key = key
        self.title = title
        self.otherTitles = otherTitles
        self.type = type
        self.kind = kind
        self.aniListId = aniListId
        self.malId = malId
    }

    var titles: [String] { [title] + otherTitles }

    /// A series' key: the service, a short hash of the server's address (ids are each server's
    /// own), and its id there.
    public static func key(service: String, server: URL?, id: String) -> String {
        let address = server?.absoluteString.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        let hash = SHA256.hash(data: Data(address.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        return "\(service):\(hash):\(id)"
    }

    /// AniList's kind of media for a key's service: Jellyfin's shows, else manga.
    public static func type(ofKey key: String) -> AniListMediaType { key.hasPrefix("jellyfin:") ? .anime : .manga }
}

/// What opening a series did for its names.
public enum CharacterNamesOutcome: Equatable, Sendable {
    /// Its cast is in the dictionary.
    case ready(characters: Int)
    /// Couldn't tell which AniList series it is: Settings or the series page asks.
    case needsPick
    /// The user said it has none, or names are off.
    case none
    /// No network and nothing kept (tried again next time).
    case failed(String)
}

/// The character names dictionary: the casts of the series open in Yomu and Miru (each app's
/// one; at most two), from AniList, as one dictionary in the shared library ("Character
/// Names", above JMnedict). Opening a series swaps its app's cast in; closing takes it out.
/// Casts are kept per series for 30 days, so switching back needs no network.
public actor CharacterNameService {
    public static let castLifetime: TimeInterval = 30 * 24 * 3600
    /// Casts kept (each a few KB and its portraits) besides the open ones.
    public static let keptCasts = 50

    let database: AppDatabase
    let library: DictionaryLibrary
    let aniList: AniListClient
    let mangaBaka: MangaBakaClient
    let portraits: PortraitStore
    let readings: any NameReadingSource
    let now: @Sendable () -> Date
    let scratch: URL

    public init(database: AppDatabase, library: DictionaryLibrary, aniList: AniListClient, mangaBaka: MangaBakaClient,
                portraits: PortraitStore, readings: (any NameReadingSource)? = nil, scratch: URL = FileManager.default.temporaryDirectory,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.database = database
        self.library = library
        self.aniList = aniList
        self.mangaBaka = mangaBaka
        self.portraits = portraits
        self.readings = readings ?? JMnedictReadings(engine: library.engine)
        self.scratch = scratch
        self.now = now
    }

    // MARK: Opening and closing

    /// The app opened a series: its cast replaces the app's last one in the dictionary.
    @discardableResult
    public func open(_ series: NamedSeries, app: String) async -> CharacterNamesOutcome {
        try? await database.writer.write { db in try CharacterNameOpenSeries(app: app, seriesKey: series.key).save(db) }
        guard isEnabled else { return .none }
        let outcome: CharacterNamesOutcome
        do {
            switch try await match(for: series) {
            case .media(let mediaKey):
                let characters = try await cast(mediaKey).count
                outcome = .ready(characters: characters)
            case .none:
                outcome = .none
            case .ask:
                outcome = .needsPick
            }
        } catch {
            outcome = .failed(error.localizedDescription)
        }
        await rebuild()
        return outcome
    }

    /// The app closed its series: its cast leaves the dictionary.
    public func close(app: String) async {
        let removed = (try? await database.writer.write { db in try CharacterNameOpenSeries.deleteOne(db, key: app) }) ?? false
        if removed { await rebuild() }
    }

    /// The user picked the series' AniList media (nil: it has no cast to show).
    public func pick(_ media: AniListMedia?, for series: NamedSeries) async throws {
        let mediaKey = media.map { Self.mediaKey(id: $0.id, type: series.type) }
        try await database.writer.write { db in
            try CharacterNameMatch(seriesKey: series.key, mediaKey: mediaKey, source: .picked, title: series.title, matchedAt: self.now()).save(db)
        }
        if let mediaKey { _ = try await cast(mediaKey, refresh: true) }
        await rebuild()
    }

    /// AniList's media for a title, for the user to pick from.
    public func candidates(_ title: String, type: AniListMediaType) async throws -> [AniListMedia] {
        try await aniList.search(title, type: type)
    }

    public var isEnabled: Bool {
        ((try? database.reader.read { try CharacterNameSettings.fetchOne($0, key: 1) }) ?? CharacterNameSettings()).enabled
    }

    public func setEnabled(_ enabled: Bool) async throws {
        try await database.writer.write { db in try CharacterNameSettings(enabled: enabled).save(db) }
        await rebuild()
    }

    // MARK: Matching

    enum Match: Equatable {
        case media(String)
        case none
        case ask
    }

    static func mediaKey(id: Int, type: AniListMediaType) -> String { "\(type.rawValue):\(id)" }

    static func mediaId(_ key: String) -> (id: Int, type: AniListMediaType)? {
        let parts = key.split(separator: ":")
        guard parts.count == 2, let type = AniListMediaType(rawValue: String(parts[0])), let id = Int(parts[1]) else { return nil }
        return (id, type)
    }

    /// Which AniList media the series is: as matched before; else the server's AniList id;
    /// its MAL id; MangaBaka's ids for the title (manga, novels); a title search with exactly
    /// one strict match. Anything less sure asks the user, never a silent guess.
    func match(for series: NamedSeries) async throws -> Match {
        let stored = try await database.reader.read { db in try CharacterNameMatch.fetchOne(db, key: series.key) }
        if let stored {
            if let mediaKey = stored.mediaKey { return .media(mediaKey) }
            if stored.source == .picked { return .none }
        }
        let found = try await find(series)
        try await database.writer.write { db in
            try CharacterNameMatch(seriesKey: series.key, mediaKey: found.map { Self.mediaKey(id: $0.id, type: series.type) },
                                   source: found?.source ?? .search, title: series.title, matchedAt: self.now()).save(db)
        }
        guard let found else { return .ask }
        return .media(Self.mediaKey(id: found.id, type: series.type))
    }

    func find(_ series: NamedSeries) async throws -> (id: Int, source: CharacterNameMatch.Source)? {
        if let id = series.aniListId, id > 0 { return (id, .server) }
        if let mal = series.malId, mal > 0, let media = try await aniList.media(malId: mal, type: series.type) { return (media.id, .linked) }
        if let kind = series.kind {
            let found = (try? await mangaBaka.match(series.title, kind: kind)) ?? []
            let ids = Set(found.compactMap(\.aniListId))
            if ids.count == 1, let id = ids.first { return (id, .linked) }
            if found.count == 1, let mal = found[0].malId, let media = try await aniList.media(malId: mal, type: series.type) {
                return (media.id, .linked)
            }
        }
        let results = try await aniList.search(series.title, type: series.type)
        let strict = Self.strictMatches(results, for: series)
        return strict.count == 1 ? (strict[0].id, .search) : nil
    }

    /// Search results whose titles include the series' own (letters and digits compared), and
    /// whose format fits it (a light novel is AniList's NOVEL; manga isn't).
    static func strictMatches(_ results: [AniListMedia], for series: NamedSeries) -> [AniListMedia] {
        let wanted = Set(series.titles.map(normalized).filter { !$0.isEmpty })
        return results.filter { media in
            switch series.kind {
            case .novel: guard media.format == "NOVEL" else { return false }
            case .manga: guard media.format != "NOVEL" else { return false }
            case nil: break
            }
            return media.allTitles.contains { wanted.contains(normalized($0)) }
        }
    }

    static func normalized(_ title: String) -> String {
        title.precomposedStringWithCompatibilityMapping.lowercased().unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init).joined()
    }

    // MARK: Casts

    /// The cast of a media: kept (under 30 days old), else fetched; a stale one when AniList
    /// can't be reached.
    func cast(_ mediaKey: String, refresh: Bool = false) async throws -> [AniListCharacter] {
        let kept = try await database.reader.read { db in try CharacterCastRecord.fetchOne(db, key: mediaKey) }
        if let kept, !refresh, now().timeIntervalSince(kept.fetchedAt) < Self.castLifetime,
           let characters = try? JSONDecoder().decode([AniListCharacter].self, from: kept.characters) {
            return characters
        }
        guard let (id, type) = Self.mediaId(mediaKey) else { return [] }
        do {
            let (media, characters) = try await aniList.cast(mediaId: id, type: type)
            let record = CharacterCastRecord(mediaKey: mediaKey, title: media.displayTitle, fetchedAt: now(),
                                             characters: try JSONEncoder().encode(characters))
            try await database.writer.write { db in try record.save(db) }
            return characters
        } catch {
            if let kept, let characters = try? JSONDecoder().decode([AniListCharacter].self, from: kept.characters) { return characters }
            throw error
        }
    }

    // MARK: The dictionary

    /// Writes the open series' casts into the dictionary and installs it (or removes it when
    /// there are none). Installing the same casts again does nothing.
    public func rebuild() async {
        let (open, casts) = (try? await database.reader.read { db -> ([String], [CharacterCastRecord]) in
            let keys = try CharacterNameOpenSeries.fetchAll(db).map(\.seriesKey)
            let mediaKeys = try CharacterNameMatch.filter(keys: keys).fetchAll(db).compactMap(\.mediaKey)
            return (mediaKeys, try CharacterCastRecord.filter(keys: Array(Set(mediaKeys))).fetchAll(db))
        }) ?? ([], [])
        guard isEnabled, !open.isEmpty, !casts.isEmpty else {
            await removeDictionary()
            return
        }
        var built: [NameDictionaryCast] = []
        for record in casts.sorted(by: { $0.mediaKey < $1.mediaKey }) {
            guard let characters = try? JSONDecoder().decode([AniListCharacter].self, from: record.characters) else { continue }
            var entries: [NameDictionaryCast.Character] = []
            for character in characters {
                let forms = await NameForms.forms(of: character, readings: readings)
                guard !forms.isEmpty else { continue }
                entries.append(.init(character: character, forms: forms, portrait: await portraits.portrait(for: character)))
            }
            built.append(NameDictionaryCast(title: record.title, characters: entries))
        }
        guard built.contains(where: { !$0.characters.isEmpty }) else {
            await removeDictionary()
            return
        }
        let zip = scratch.appending(path: "character-names-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: zip) }
        do {
            try NameDictionaryBuilder.write(built, to: zip)
            let outcome = try await library.importDictionary(at: zip)
            if !outcome.replacedPrevious { try await placeAboveNames(outcome.dictionary.id) }
        } catch DictionaryError.alreadyInstalled {
            // The same casts as installed.
        } catch {
            return
        }
        await pruneCasts()
    }

    /// A new names dictionary goes just above JMnedict (below the word dictionaries).
    func placeAboveNames(_ id: String) async throws {
        var ids = try library.dictionaries().map(\.id).filter { $0 != id }
        let records = try library.dictionaries()
        let position = records.filter { $0.id != id }.firstIndex { record in
            NameRanking.namePrefixes.contains { record.title.hasPrefix($0) && $0 != NameDictionaryBuilder.title }
        } ?? ids.count
        ids.insert(id, at: position)
        try await library.reorder(ids)
    }

    func removeDictionary() async {
        guard let record = try? library.dictionaries().first(where: { $0.title == NameDictionaryBuilder.title }) else { return }
        try? await library.delete(record.id)
    }

    /// Keeps the newest casts (and the open ones) and their portraits.
    func pruneCasts() async {
        let keep = try? await database.writer.write { db -> [CharacterCastRecord] in
            let keys = try CharacterNameOpenSeries.fetchAll(db).map(\.seriesKey)
            let open = Set(try CharacterNameMatch.filter(keys: keys).fetchAll(db).compactMap(\.mediaKey))
            let all = try CharacterCastRecord.order(Column("fetchedAt").desc).fetchAll(db)
            var kept: [CharacterCastRecord] = []
            for (index, record) in all.enumerated() {
                if index < Self.keptCasts || open.contains(record.mediaKey) {
                    kept.append(record)
                } else {
                    _ = try record.delete(db)
                }
            }
            return kept
        }
        guard let keep else { return }
        var ids = Set<Int>()
        for record in keep {
            for character in (try? JSONDecoder().decode([AniListCharacter].self, from: record.characters)) ?? [] { ids.insert(character.id) }
        }
        portraits.prune(keeping: ids)
    }
}

/// JMnedict's readings for a name spelled exactly so (to check a reading from romaji).
public struct JMnedictReadings: NameReadingSource {
    let engine: DictionaryEngine

    public init(engine: DictionaryEngine) {
        self.engine = engine
    }

    public func readings(of expression: String) async -> [String] {
        let results = await engine.lookup(expression, maxResults: 32, scanLength: expression.count)
        var readings: [String] = []
        for result in results where result.matched == expression && result.expression == expression
            && result.glossaries.contains(where: { $0.dictionary.hasPrefix("JMnedict") }) && !readings.contains(result.reading) {
            readings.append(result.reading)
        }
        return readings
    }
}
