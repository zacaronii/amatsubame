import CHoshiDicts
import Core
import Foundation
import GRDB

public struct DictionaryImportOutcome: Equatable, Sendable {
    public var dictionary: DictionaryRecord
    /// True when an older revision with the same title was replaced.
    public var replacedPrevious: Bool
    public var seconds: Double
}

/// A Yomitan dictionary's `index.json`: what it is and, for self-updating ones, where its
/// newest version is (`indexUrl`: the index alone; `downloadUrl`: the zip).
public struct DictionaryIndex: Decodable, Equatable, Sendable {
    public var title: String?
    public var revision: String?
    public var attribution: String?
    public var isUpdatable: Bool?
    public var indexUrl: String?
    public var downloadUrl: String?

    public init(title: String? = nil, revision: String? = nil, attribution: String? = nil,
                isUpdatable: Bool? = nil, indexUrl: String? = nil, downloadUrl: String? = nil) {
        self.title = title
        self.revision = revision
        self.attribution = attribution
        self.isUpdatable = isUpdatable
        self.indexUrl = indexUrl
        self.downloadUrl = downloadUrl
    }
}

/// Installed dictionaries: imports Yomitan zips with hoshidicts, keeps their
/// metadata in GRDB, and keeps the engine loaded with the enabled ones in order.
public final class DictionaryLibrary: Sendable {
    public let database: AppDatabase
    /// Holds one hoshidicts folder per dictionary, named by record id.
    public let directory: URL
    public let engine: DictionaryEngine
    /// A second lookup over the same dictionaries, for word marks.
    public let scanner = WordScanner()
    /// hoshidicts' low-memory import mode; slower but safer on phones.
    let lowMemoryImport: Bool

    public init(database: AppDatabase, directory: URL, engine: DictionaryEngine = DictionaryEngine(), lowMemoryImport: Bool = false) {
        self.database = database
        self.directory = directory
        self.engine = engine
        self.lowMemoryImport = lowMemoryImport
    }

    public func folder(for record: DictionaryRecord) -> URL {
        directory.appending(path: record.folderName, directoryHint: .isDirectory)
    }

    public func dictionaries() throws -> [DictionaryRecord] {
        try database.reader.read { try DictionaryRecord.order(Column("sortOrder"), Column("title")).fetchAll($0) }
    }

    public func observeDictionaries() -> AsyncThrowingStream<[DictionaryRecord], any Error> {
        database.values { try DictionaryRecord.order(Column("sortOrder"), Column("title")).fetchAll($0) }
    }

    public func settings() throws -> DictionarySettings {
        try database.reader.read { try DictionarySettings.fetchOne($0, key: 1) } ?? DictionarySettings()
    }

    /// Changes the settings row (read and written in one transaction).
    public func updateSettings(_ change: @escaping @Sendable (inout DictionarySettings) -> Void) async throws {
        try await database.writer.write { db in
            var settings = try DictionarySettings.fetchOne(db, key: 1) ?? DictionarySettings()
            change(&settings)
            try settings.save(db)
        }
    }

    /// Where each installed dictionary came from, by dictionary id.
    public func sources() throws -> [String: DictionarySource] {
        try database.reader.read { db in
            Dictionary(uniqueKeysWithValues: try DictionarySource.fetchAll(db).map { ($0.dictionaryId, $0) })
        }
    }

    public func saveSource(_ source: DictionarySource) async throws {
        try await database.writer.write { db in try source.save(db) }
    }

    /// The installed `index.json` (hoshidicts keeps the zip's, with every field).
    public func installedIndex(of record: DictionaryRecord) -> DictionaryIndex? {
        Self.readIndex(in: folder(for: record))
    }

    // MARK: Import

    /// Imports a Yomitan dictionary zip. A newer revision of an installed dictionary replaces
    /// it in place (keeping its id, order and enabled state); the same revision again is
    /// rejected. `replacing`: the dictionary this updates (its title may have changed, as
    /// Jitendex's does with each version); otherwise one with the same title.
    /// `catalogId`: its entry in the recommended set.
    @discardableResult
    public func importDictionary(at zip: URL, replacing: String? = nil, catalogId: String? = nil) async throws -> DictionaryImportOutcome {
        let started = Date()
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let staging = directory.appending(path: ".import-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        let summary = try await Task.detached(priority: .userInitiated) { [lowMemoryImport] in
            try Self.runImport(zip: zip, into: staging, lowMemory: lowMemoryImport)
        }.value

        guard let imported = try fileManager.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil).first(where: \.hasDirectoryPath) else {
            throw DictionaryError.importFailed("The importer produced no dictionary folder.")
        }
        return try await install(imported, summary: summary, started: started, copy: false,
                                 replacing: replacing, catalogId: catalogId)
    }

    /// Converts a zip on the Mac into a prebuilt package (`<name>.hoshidict`: the hoshidicts
    /// folder plus `summary.json`) that `installPrebuilt` can add without the heavy import.
    /// The Safari extension gets its built-in dictionaries this way: on an iPad mini, importing
    /// a large frequency dictionary is more than iOS allows an extension.
    public static func prebuild(zip: URL, into package: URL) throws {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: package)
        try fileManager.createDirectory(at: package, withIntermediateDirectories: true)
        let summary = try runImport(zip: zip, into: package, lowMemory: false)
        try JSONEncoder().encode(summary).write(to: package.appending(path: "summary.json"))
    }

    /// Adds a dictionary prebuilt with `prebuild` (copying its folder; nothing heavy).
    @discardableResult
    public func installPrebuilt(at package: URL) async throws -> DictionaryImportOutcome {
        let summary = try JSONDecoder().decode(ImportSummary.self, from: Data(contentsOf: package.appending(path: "summary.json")))
        guard let folder = try FileManager.default.contentsOfDirectory(at: package, includingPropertiesForKeys: nil)
            .first(where: \.hasDirectoryPath) else {
            throw DictionaryError.importFailed("The prebuilt dictionary has no folder.")
        }
        return try await install(folder, summary: summary, started: Date(), copy: true)
    }

    /// Moves (or copies) an imported hoshidicts folder into place and records it; a newer
    /// revision of an installed dictionary replaces it in place.
    private func install(_ imported: URL, summary: ImportSummary, started: Date, copy: Bool,
                         replacing: String? = nil, catalogId: String? = nil) async throws -> DictionaryImportOutcome {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let index = Self.readIndex(in: imported) ?? DictionaryIndex()
        let (existing, sameTitle) = try await database.reader.read { db in
            (try replacing.flatMap { try DictionaryRecord.fetchOne(db, key: $0) }
                ?? DictionaryRecord.filter(Column("title") == summary.title).fetchOne(db),
             try DictionaryRecord.filter(Column("title") == summary.title).fetchOne(db))
        }
        if let existing, existing.revision == index.revision {
            throw DictionaryError.alreadyInstalled(title: summary.title, revision: existing.revision)
        }
        // Another dictionary already has the new title (installed separately).
        if let sameTitle, sameTitle.id != existing?.id {
            throw DictionaryError.alreadyInstalled(title: summary.title, revision: sameTitle.revision)
        }

        // An update keeps the id and goes in a new folder beside the old one, which the engine
        // may still be reading until it reloads.
        let id = existing?.id ?? UUID().uuidString
        let folderName = existing == nil ? id : "\(id)-\(UUID().uuidString.prefix(8))"
        let destination = directory.appending(path: folderName, directoryHint: .isDirectory)
        if copy {
            try fileManager.copyItem(at: imported, to: destination)
        } else {
            try fileManager.moveItem(at: imported, to: destination)
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var excluded = destination
        try? excluded.setResourceValues(values)

        let nextOrder = try await database.reader.read { db in
            try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(sortOrder), -1) + 1 FROM dictionary") ?? 0
        }
        let record = DictionaryRecord(
            id: id, title: summary.title, revision: index.revision, attribution: index.attribution,
            hasTerms: summary.terms > 0, hasFrequencies: summary.frequencies > 0, hasPitches: summary.pitches > 0,
            hasKanji: summary.kanji > 0, termCount: summary.terms, metaCount: summary.meta, kanjiCount: summary.kanji,
            mediaCount: summary.media, bytes: Self.size(of: destination),
            enabled: existing?.enabled ?? true, sortOrder: existing?.sortOrder ?? nextOrder, importedAt: Date(),
            folder: existing == nil ? nil : folderName
        )
        try await database.writer.write { db in
            let previousSource = try DictionarySource.fetchOne(db, key: id)
            if let existing {
                try record.update(db)
                // Settings that name the dictionary by title follow it to its new one.
                if existing.title != record.title {
                    try db.execute(sql: "UPDATE dictionarySettings SET frequencySortTitle = ? WHERE frequencySortTitle = ?",
                                   arguments: [record.title, existing.title])
                }
            } else {
                try record.insert(db)
            }
            // The revision is the installed zip's; the update address is its own index's.
            try DictionarySource(
                dictionaryId: id, catalogId: catalogId ?? previousSource?.catalogId,
                indexUrl: index.indexUrl ?? previousSource?.indexUrl, downloadUrl: index.downloadUrl ?? previousSource?.downloadUrl,
                isUpdatable: index.isUpdatable ?? false, checkedAt: previousSource?.checkedAt
            ).save(db)
        }
        try await reloadEngine()
        if let existing { try? fileManager.removeItem(at: folder(for: existing)) }
        return DictionaryImportOutcome(dictionary: record, replacedPrevious: existing != nil,
                                       seconds: Date().timeIntervalSince(started))
    }

    /// Leftovers of imports that never finished (the process was stopped mid-import), and
    /// folders no dictionary uses (an update stopped before its old folder was removed).
    /// Only ones untouched for an hour, as another app sharing the folder may be installing.
    public func removeUnfinishedImports(olderThan age: TimeInterval = 3600) {
        let fileManager = FileManager.default
        let names = (try? fileManager.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
        let used = Set((try? dictionaries())?.map(\.folderName) ?? [])
        for name in names where name.hasPrefix(".import-") || !name.hasPrefix(".") && !used.contains(name) {
            let url = directory.appending(path: name)
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            guard Date().timeIntervalSince(modified) > age else { continue }
            try? fileManager.removeItem(at: url)
        }
    }

    struct ImportSummary: Codable, Sendable {
        var title: String
        var terms: Int
        var meta: Int
        var frequencies: Int
        var pitches: Int
        var kanji: Int
        var media: Int
    }

    private static func runImport(zip: URL, into staging: URL, lowMemory: Bool) throws -> ImportSummary {
        guard let result = hd_import(zip.path(percentEncoded: false), staging.path(percentEncoded: false), lowMemory ? 1 : 0) else {
            throw DictionaryError.importFailed("The importer couldn't start.")
        }
        defer { hd_import_result_free(result) }
        guard hd_import_result_success(result) != 0 else {
            let message = hd_import_result_error(result).map { String(cString: $0) } ?? ""
            throw DictionaryError.importFailed(message.isEmpty ? "Is this a Yomitan dictionary zip?" : message)
        }
        return ImportSummary(
            title: String(cString: hd_import_result_title(result)),
            terms: Int(hd_import_result_term_count(result)),
            meta: Int(hd_import_result_meta_count(result)),
            frequencies: Int(hd_import_result_freq_count(result)),
            pitches: Int(hd_import_result_pitch_count(result)),
            kanji: Int(hd_import_result_kanji_count(result)),
            media: Int(hd_import_result_media_count(result))
        )
    }

    private static func readIndex(in folder: URL) -> DictionaryIndex? {
        guard let data = try? Data(contentsOf: folder.appending(path: "index.json")),
              var index = try? JSONDecoder().decode(DictionaryIndex.self, from: data) else { return nil }
        // hoshidicts copies the zip's strings with their JSON escapes still in (`https:\/\/…`, `\n`).
        index.revision = index.revision.map(unescaped)
        index.attribution = index.attribution.map(unescaped)
        index.indexUrl = index.indexUrl.map(unescaped)
        index.downloadUrl = index.downloadUrl.map(unescaped)
        return index
    }

    static func unescaped(_ raw: String) -> String {
        guard raw.contains("\\") else { return raw }
        return (try? JSONDecoder().decode(String.self, from: Data("\"\(raw)\"".utf8))) ?? raw
    }

    private static func size(of folder: URL) -> Int {
        let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey])
        var total = 0
        while let file = files?.nextObject() as? URL {
            total += (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        return total
    }

    // MARK: Management

    /// Deletes a dictionary. A recommended one is remembered, so it isn't installed again.
    public func delete(_ id: String) async throws {
        guard let record = try await database.writer.write({ db -> DictionaryRecord? in
            let record = try DictionaryRecord.fetchOne(db, key: id)
            if let catalogId = try DictionarySource.fetchOne(db, key: id)?.catalogId {
                var settings = try DictionarySettings.fetchOne(db, key: 1) ?? DictionarySettings()
                if !settings.removedRecommended.contains(catalogId) { settings.removedRecommended.append(catalogId) }
                try settings.save(db)
            }
            _ = try DictionaryRecord.deleteOne(db, key: id)
            return record
        }) else { throw DictionaryError.notFound }
        try await reloadEngine()
        try? FileManager.default.removeItem(at: folder(for: record))
    }

    public func setEnabled(_ id: String, _ enabled: Bool) async throws {
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE dictionary SET enabled = ? WHERE id = ?", arguments: [enabled, id])
        }
        try await reloadEngine()
    }

    /// Sets the order dictionaries appear in results (ids in the new order).
    public func reorder(_ ids: [String]) async throws {
        try await database.writer.write { db in
            for (order, id) in ids.enumerated() {
                try db.execute(sql: "UPDATE dictionary SET sortOrder = ? WHERE id = ?", arguments: [order, id])
            }
        }
        try await reloadEngine()
    }

    public func setFrequencySortDictionary(_ title: String?) async throws {
        try await updateSettings { $0.frequencySortTitle = title }
        try await reloadEngine()
    }

    /// Loads the enabled dictionaries, in order, into the engine.
    public func reloadEngine() async throws {
        let enabled = try dictionaries().filter(\.enabled)
        let sortTitle = try settings().frequencySortTitle.flatMap { title in
            enabled.contains { $0.title == title && $0.hasFrequencies } ? title : nil
        }
        let loaded = enabled.map {
            EngineDictionary(title: $0.title, folder: folder(for: $0), hasTerms: $0.hasTerms,
                             hasFrequencies: $0.hasFrequencies, hasPitches: $0.hasPitches, hasKanji: $0.hasKanji)
        }
        try await engine.configure(loaded, frequencySortTitle: sortTitle)
        await scanner.configure(loaded, frequencySortTitle: sortTitle)
    }
}
