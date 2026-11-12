import AVFoundation
import Core
import CryptoKit
import Foundation
import GRDB

/// Word audio from the user's sources, tried in order like Yomitan: the first
/// source with a playable clip wins.
@MainActor @Observable
public final class AudioService {
    public enum Status: Equatable {
        case idle
        case loading
        case playing(source: String)
        case unavailable
    }

    public private(set) var status = Status.idle
    private let database: AppDatabase
    private let http: HTTPClient
    /// Where the sources' keys go (`AudioSourceKeys`); nil keeps them in the templates.
    private let secrets: (any SecretStore)?
    private var player: AVAudioPlayer?
    private var task: Task<Void, Never>?

    public init(database: AppDatabase, http: HTTPClient = HTTPClient(), secrets: (any SecretStore)? = nil) {
        self.database = database
        self.http = http
        self.secrets = secrets
    }

    /// JapanesePod101's "audio not available" clip (SHA-256), which Yomitan also filters out.
    nonisolated static let jpod101Missing = "ae6398b5a27bc8c0a771df6c907ade794be15518174773c58c7c7ddd17098906"

    public static let defaultSources = [
        AudioSourceRecord(kind: .jpod101, name: "JapanesePod101", template: "", sortOrder: 0),
    ]

    public func sources() throws -> [AudioSourceRecord] {
        try database.reader.read { try AudioSourceRecord.order(Column("sortOrder")).fetchAll($0) }
    }

    /// Adds or updates a source (in the shared setup when the app shares it). Keys in its
    /// template go to the Keychain; if that fails they stay in the template rather than be lost.
    public func save(_ source: AudioSourceRecord) throws {
        var source = source
        let split = AudioSourceKeys.split(source.template)
        if !split.keys.isEmpty, let secrets {
            var keys = keys()
            keys.merge(split.keys) { $1 }
            if (try? secrets.setSecret(Self.encode(keys), for: .audioSourceKeys)) != nil {
                source.template = split.template
            }
        }
        try database.writer.write { try source.save($0) }
        dropUnusedKeys()
    }

    /// A source's template with its keys, to edit.
    public func editableTemplate(_ source: AudioSourceRecord) -> String {
        AudioSourceKeys.filled(source.template, keys: keys())
    }

    /// Moves keys still written in templates (saved before the Keychain held them) there.
    public func moveKeysToKeychain() throws {
        guard secrets != nil else { return }
        for source in try sources() where !AudioSourceKeys.split(source.template).keys.isEmpty {
            try save(source)
        }
    }

    private func keys() -> [String: String] {
        guard let json = try? secrets?.secret(for: .audioSourceKeys) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: Data(json.utf8))) ?? [:]
    }

    private static func encode(_ keys: [String: String]) -> String? {
        keys.isEmpty ? nil : (try? JSONEncoder().encode(keys)).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Forgets the keys no source uses any more (deleted sources, edited templates).
    private func dropUnusedKeys() {
        guard let secrets, let sources = try? sources() else { return }
        let used = Set(sources.flatMap { AudioSourceKeys.placeholderIds($0.template) })
        let keys = keys()
        let kept = keys.filter { used.contains($0.key) }
        if kept != keys { try? secrets.setSecret(Self.encode(kept), for: .audioSourceKeys) }
    }

    /// Stores the sources' order as shown.
    public func reorder(_ sources: [AudioSourceRecord]) throws {
        try database.writer.write { db in
            for (index, var source) in sources.enumerated() {
                source.sortOrder = index
                try source.update(db)
            }
        }
    }

    public func delete(ids: [Int64]) throws {
        _ = try database.writer.write { try AudioSourceRecord.deleteAll($0, keys: ids) }
        dropUnusedKeys()
    }

    /// Adds the default sources the first time the app runs.
    public func installDefaultSourcesIfNeeded() throws {
        try database.writer.write { db in
            guard try AudioSourceRecord.fetchCount(db) == 0 else { return }
            for var source in Self.defaultSources { try source.insert(db) }
        }
    }

    public func play(term: String, reading: String) {
        task?.cancel()
        player?.stop()
        status = .loading
        let enabled = ((try? sources()) ?? []).filter(\.enabled)
        task = Task {
            for source in enabled {
                if Task.isCancelled { return }
                for url in await candidates(source, term: term, reading: reading) {
                    guard let data = await fetchAudio(url, source: source), let player = try? AVAudioPlayer(data: data) else { continue }
                    if Task.isCancelled { return }
                    startPlayback(player)
                    status = .playing(source: source.name)
                    return
                }
            }
            status = .unavailable
        }
    }

    /// The first clip the enabled sources have for a word, without playing it (for mined cards).
    public func firstClip(term: String, reading: String) async -> (data: Data, fileExtension: String)? {
        let enabled = ((try? sources()) ?? []).filter(\.enabled)
        for source in enabled {
            for url in await candidates(source, term: term, reading: reading) {
                if let data = await fetchAudio(url, source: source) {
                    return (data, Self.fileExtension(for: url))
                }
            }
        }
        return nil
    }

    /// The URL's audio extension, or mp3 (JapanesePod101's audiomp3.php and most servers).
    nonisolated static func fileExtension(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        return ["mp3", "m4a", "aac", "ogg", "oga", "opus", "wav", "flac"].contains(ext) ? ext : "mp3"
    }

    public func stop() {
        task?.cancel()
        player?.stop()
        status = .idle
    }

    private func startPlayback(_ player: AVAudioPlayer) {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        // An app already playing for itself (the Player's video) keeps its session: making
        // it mix with others hands the headphone and Lock Screen controls to other apps.
        if session.category != .playback {
            try? session.setCategory(.playback, options: [.duckOthers])
        }
        try? session.setActive(true)
        #endif
        self.player = player
        player.play()
    }

    // MARK: Sources

    nonisolated static func expand(_ template: String, term: String, reading: String) -> URL? {
        func encoded(_ value: String) -> String {
            value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+?#/"))) ?? value
        }
        let expanded = template
            .replacingOccurrences(of: "{term}", with: encoded(term))
            .replacingOccurrences(of: "{reading}", with: encoded(reading.isEmpty ? term : reading))
        return URL(string: expanded)
    }

    /// Yomitan's JapanesePod101 URL: kana-only words send just `kana`.
    nonisolated static func jpod101URL(term: String, reading: String) -> URL {
        var kanji = term
        var kana = reading
        if (reading.isEmpty || reading == term), term.allSatisfy({ $0.unicodeScalars.allSatisfy { (0x3040...0x30FF).contains($0.value) } }) {
            kana = term
            kanji = ""
        }
        var components = URLComponents(string: "https://assets.languagepod101.com/dictionary/japanese/audiomp3.php")!
        components.queryItems = [
            kanji.isEmpty ? nil : URLQueryItem(name: "kanji", value: kanji),
            kana.isEmpty ? nil : URLQueryItem(name: "kana", value: kana),
        ].compactMap { $0 }
        return components.url!
    }

    func candidates(_ source: AudioSourceRecord, term: String, reading: String) async -> [URL] {
        var source = source
        source.template = editableTemplate(source)
        switch source.kind {
        case .jpod101:
            return [Self.jpod101URL(term: term, reading: reading)]
        case .url:
            return Self.expand(source.template, term: term, reading: reading).map { [$0] } ?? []
        case .json:
            guard let url = Self.expand(source.template, term: term, reading: reading),
                  let response = try? await http.send(.get(url)) else { return [] }
            return Self.parseAudioList(response.data, base: url)
        }
    }

    /// Yomitan's custom JSON: `{"type": "audioSourceList", "audioSources": [{"url": …, "name": …}]}`.
    nonisolated static func parseAudioList(_ data: Data, base: URL) -> [URL] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["type"] as? String == "audioSourceList",
              let sources = json["audioSources"] as? [[String: Any]] else { return [] }
        return sources.compactMap { ($0["url"] as? String).flatMap { URL(string: $0, relativeTo: base)?.absoluteURL } }
    }

    func fetchAudio(_ url: URL, source: AudioSourceRecord) async -> Data? {
        var request = URLRequest(url: url, timeoutInterval: 4)
        request.setValue("audio/*, */*", forHTTPHeaderField: "Accept")
        guard let response = try? await http.send(request) else { return nil }
        return Self.isValidAudio(response.data, contentType: response.response.value(forHTTPHeaderField: "Content-Type"), kind: source.kind)
            ? response.data : nil
    }

    nonisolated static func isValidAudio(_ data: Data, contentType: String?, kind: AudioSourceRecord.Kind) -> Bool {
        guard !data.isEmpty else { return false }
        if let contentType, contentType.hasPrefix("text/") || contentType.contains("json") { return false }
        if kind == .jpod101 {
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            return digest != jpod101Missing
        }
        return true
    }
}
