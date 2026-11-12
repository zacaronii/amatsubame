import Foundation
import GRDB

/// A Kaku transcript saved on the device for one podcast episode or book (Kiku). `key` is
/// "<library item id>/<episode id>" (the item id alone for a book), the same key downloads and
/// progress use.
public struct AudioTranscriptInfo: Codable, Equatable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "audioTranscript"

    public var key: String
    public var itemId: String
    public var episodeId: String
    public var showTitle: String
    public var episodeTitle: String
    /// Kaku's audio fingerprint: a changed episode gets a fresh transcript.
    public var fingerprint: String?
    public var duration: Double?
    public var savedAt: Date
    /// Set when the episode is played; Marks search covers played episodes.
    public var lastPlayedAt: Date?

    public init(itemId: String, episodeId: String, showTitle: String, episodeTitle: String, fingerprint: String?,
                duration: Double?, savedAt: Date, lastPlayedAt: Date? = nil) {
        key = Self.key(itemId: itemId, episodeId: episodeId)
        self.itemId = itemId
        self.episodeId = episodeId
        self.showTitle = showTitle
        self.episodeTitle = episodeTitle
        self.fingerprint = fingerprint
        self.duration = duration
        self.savedAt = savedAt
        self.lastPlayedAt = lastPlayedAt
    }

    /// "<item>/<episode>", or the item alone for a book (its episode id is empty).
    public static func key(itemId: String, episodeId: String) -> String { episodeId.isEmpty ? itemId : "\(itemId)/\(episodeId)" }
}

/// One sentence of a saved transcript, with its words' timings.
public struct AudioSentence: Codable, Equatable, Hashable, Sendable {
    public struct Word: Codable, Equatable, Hashable, Sendable {
        public var text: String
        public var start: Double
        public var end: Double

        public init(text: String, start: Double, end: Double) {
            self.text = text
            self.start = start
            self.end = end
        }
    }

    public var key: String
    /// Its place in the transcript, from 0.
    public var position: Int
    public var start: Double
    public var end: Double
    public var text: String
    public var words: [Word]

    public init(key: String, position: Int, start: Double, end: Double, text: String, words: [Word] = []) {
        self.key = key
        self.position = position
        self.start = start
        self.end = end
        self.text = text
        self.words = words
    }
}

/// Sentences matching a search, grouped by episode.
public struct AudioSearchGroup: Equatable, Sendable, Identifiable {
    public var transcript: AudioTranscriptInfo
    public var sentences: [AudioSentence]
    public var id: String { transcript.key }
}

public struct AudioTranscriptStore: Sendable {
    let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    /// Saves (or replaces) an episode's transcript, keeping when it was last played.
    public func save(_ info: AudioTranscriptInfo, sentences: [AudioSentence]) throws {
        try database.writer.write { db in
            var info = info
            if let old = try AudioTranscriptInfo.fetchOne(db, key: info.key) {
                info.lastPlayedAt = info.lastPlayedAt ?? old.lastPlayedAt
            }
            try info.save(db)
            try db.execute(sql: "DELETE FROM audioSentence WHERE key = ?", arguments: [info.key])
            try db.execute(sql: "DELETE FROM audioSentenceSearch WHERE key = ?", arguments: [info.key])
            let encoder = JSONEncoder()
            let insert = try db.makeStatement(
                sql: #"INSERT INTO audioSentence (key, position, start, "end", text, words) VALUES (?, ?, ?, ?, ?, ?)"#)
            let index = try db.makeStatement(sql: "INSERT INTO audioSentenceSearch (text, key, position) VALUES (?, ?, ?)")
            for (position, sentence) in sentences.enumerated() {
                let words = sentence.words.isEmpty ? nil : try encoder.encode(sentence.words)
                try insert.execute(arguments: [info.key, position, sentence.start, sentence.end, sentence.text, words])
                try index.execute(arguments: [sentence.text, info.key, position])
            }
        }
    }

    public func transcript(key: String) throws -> AudioTranscriptInfo? {
        try database.reader.read { db in try AudioTranscriptInfo.fetchOne(db, key: key) }
    }

    public func savedKeys() throws -> Set<String> {
        try database.reader.read { db in Set(try String.fetchAll(db, sql: "SELECT key FROM audioTranscript")) }
    }

    public func sentences(key: String) throws -> [AudioSentence] {
        try database.reader.read { db in
            try Row.fetchAll(db, sql: #"SELECT key, position, start, "end", text, words FROM audioSentence WHERE key = ? ORDER BY position"#,
                             arguments: [key]).map(Self.sentence)
        }
    }

    /// Records that an episode was played (Marks search covers played episodes).
    public func touch(key: String, at date: Date) throws {
        try database.writer.write { db in
            try db.execute(sql: "UPDATE audioTranscript SET lastPlayedAt = ? WHERE key = ?", arguments: [date, key])
        }
    }

    /// Sentences containing `query` in played episodes, grouped by episode (most recently played
    /// first). Like Miru's search: the trigram index from three characters, LIKE below that.
    public func search(_ query: String, limit: Int = 300) throws -> [AudioSearchGroup] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        return try database.reader.read { db in
            let hits: [Row]
            if query.count >= 3 {
                let phrase = "\"" + query.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                hits = try Row.fetchAll(db, sql: """
                    SELECT s.key, s.position, s.start, s."end", s.text, s.words FROM audioSentenceSearch f
                    JOIN audioSentence s ON s.key = f.key AND s.position = f.position
                    JOIN audioTranscript t ON t.key = s.key
                    WHERE audioSentenceSearch MATCH ? AND t.lastPlayedAt IS NOT NULL LIMIT ?
                    """, arguments: [phrase, limit])
            } else {
                let escaped = query.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
                hits = try Row.fetchAll(db, sql: #"""
                    SELECT s.key, s.position, s.start, s."end", s.text, s.words FROM audioSentence s
                    JOIN audioTranscript t ON t.key = s.key
                    WHERE s.text LIKE ? ESCAPE '\' AND t.lastPlayedAt IS NOT NULL LIMIT ?
                    """#, arguments: ["%\(escaped)%", limit])
            }
            let sentences = hits.map(Self.sentence)
            let infos = try AudioTranscriptInfo.fetchAll(db, keys: Set(sentences.map(\.key)))
            return infos
                .sorted { ($0.lastPlayedAt ?? $0.savedAt) > ($1.lastPlayedAt ?? $1.savedAt) }
                .map { info in
                    AudioSearchGroup(transcript: info, sentences: sentences.filter { $0.key == info.key }.sorted { $0.position < $1.position })
                }
        }
    }

    public func delete(key: String) throws {
        try database.writer.write { db in
            try db.execute(sql: "DELETE FROM audioSentence WHERE key = ?", arguments: [key])
            try db.execute(sql: "DELETE FROM audioSentenceSearch WHERE key = ?", arguments: [key])
            _ = try AudioTranscriptInfo.deleteOne(db, key: key)
        }
    }

    /// Roughly how much space saved transcripts take, index and word timings included.
    public func approximateBytes() throws -> Int {
        try database.reader.read { db in
            let text = try Int.fetchOne(db, sql: "SELECT COALESCE(SUM(length(CAST(text AS BLOB))), 0) FROM audioSentence") ?? 0
            let words = try Int.fetchOne(db, sql: "SELECT COALESCE(SUM(length(words)), 0) FROM audioSentence") ?? 0
            return text * 4 + words
        }
    }

    private static func sentence(_ row: Row) -> AudioSentence {
        let words = (row["words"] as Data?).flatMap { try? JSONDecoder().decode([AudioSentence.Word].self, from: $0) } ?? []
        return AudioSentence(key: row["key"], position: row["position"], start: row["start"], end: row["end"], text: row["text"], words: words)
    }
}

/// Kiku's playback settings.
public struct ListenSettings: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "listenSettings"
    var id = 1
    /// Seconds the Lock Screen, AirPods and CarPlay skip back and forward (the player itself
    /// jumps by lines instead).
    public var skipBackward: Double = 15
    public var skipForward: Double = 30
    /// The speed a new episode starts at.
    public var speed: Double = 1
    /// Audiobookshelf libraries Kiku doesn't show (e.g. one in English), by id.
    public var hiddenLibraries: [String] = []
    /// The player shows the transcript (its speech-bubble button), for every episode.
    public var showsTranscript = true

    public static let skipChoices: [Double] = [10, 15, 30, 45, 60]
    public static let speeds: [Double] = [0.75, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2]

    public init(skipBackward: Double = 15, skipForward: Double = 30, speed: Double = 1, hiddenLibraries: [String] = [],
                showsTranscript: Bool = true) {
        self.skipBackward = skipBackward
        self.skipForward = skipForward
        self.speed = speed
        self.hiddenLibraries = hiddenLibraries
        self.showsTranscript = showsTranscript
    }

    public static func load(_ database: AppDatabase) -> ListenSettings {
        (try? database.reader.read { try ListenSettings.fetchOne($0, key: 1) }) ?? ListenSettings()
    }

    public func save(_ database: AppDatabase) throws {
        try database.writer.write { try self.save($0) }
    }
}

/// Kiku's last answers from Audiobookshelf (the home shelves, each show's episodes), kept as
/// the server's JSON so the library still shows when the phone is offline.
public struct AudiobookshelfCacheStore: Sendable {
    let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func data(for key: String) throws -> Data? {
        try database.writer.read { db in
            try Data.fetchOne(db, sql: "SELECT raw FROM audiobookshelfCache WHERE key = ?", arguments: [key])
        }
    }

    public func save(_ raw: Data, for key: String) throws {
        try database.writer.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO audiobookshelfCache (key, raw, fetchedAt) VALUES (?, ?, ?)",
                           arguments: [key, raw, Date()])
        }
    }

    /// Forgets everything (signing out, or another server).
    public func clear() throws {
        try database.writer.write { try $0.execute(sql: "DELETE FROM audiobookshelfCache") }
    }
}
