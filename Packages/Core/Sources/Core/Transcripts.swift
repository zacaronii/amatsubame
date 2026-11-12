import Foundation
import GRDB

/// A saved subtitle track of one episode or movie (the Lines tab).
public struct TranscriptInfo: Codable, Equatable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "transcript"

    public var itemId: String
    public var seriesId: String?
    public var seriesName: String?
    public var title: String
    public var season: Int?
    public var episode: Int?
    /// What to stream for mining and "Play from here".
    public var mediaSourceId: String
    /// The subtitle stream the lines came from.
    public var streamIndex: Int
    /// The Japanese audio stream as FFmpeg numbers it, for sentence audio; nil for the default.
    public var audioIndex: Int?
    public var runtime: Double?
    public var lastPlayedAt: Date?
    public var savedAt: Date

    public init(itemId: String, seriesId: String?, seriesName: String?, title: String, season: Int?, episode: Int?,
                mediaSourceId: String, streamIndex: Int, audioIndex: Int? = nil, runtime: Double?, lastPlayedAt: Date?,
                savedAt: Date) {
        self.itemId = itemId
        self.seriesId = seriesId
        self.seriesName = seriesName
        self.title = title
        self.season = season
        self.episode = episode
        self.mediaSourceId = mediaSourceId
        self.streamIndex = streamIndex
        self.audioIndex = audioIndex
        self.runtime = runtime
        self.lastPlayedAt = lastPlayedAt
        self.savedAt = savedAt
    }
}

/// One subtitle line of a saved transcript.
public struct TranscriptLine: Equatable, Hashable, Sendable {
    public var itemId: String
    /// Position in the track.
    public var cue: Int
    public var start: Double
    public var end: Double
    public var text: String

    public init(itemId: String, cue: Int, start: Double, end: Double, text: String) {
        self.itemId = itemId
        self.cue = cue
        self.start = start
        self.end = end
        self.text = text
    }
}

/// Search results for one episode.
public struct TranscriptSearchGroup: Equatable, Sendable, Identifiable {
    public var transcript: TranscriptInfo
    public var lines: [TranscriptLine]
    public var id: String { transcript.itemId }
}

public enum TranscriptLines {
    /// Lines with the same text that overlap or nearly touch become one, from the earliest start to the
    /// latest end. Fansub files draw song lyrics as many copies of a line, one per animation step.
    /// `sorted` is in start order.
    public static func mergingCopies(_ sorted: [(start: Double, end: Double, text: String)],
                                     gap: Double = 0.5) -> [(start: Double, end: Double, text: String)] {
        var merged: [(start: Double, end: Double, text: String)] = []
        var lastWithText: [String: Int] = [:]
        for line in sorted {
            if let index = lastWithText[line.text], line.start - merged[index].end < gap {
                merged[index].end = max(merged[index].end, line.end)
            } else {
                lastWithText[line.text] = merged.count
                merged.append(line)
            }
        }
        return merged
    }

    /// Karaoke build-ups become their finished line: a line that the next one starts with
    /// (「恋」 then 「恋をしたから」), straight after it, is folded into it, which keeps the first
    /// one's start. For the Lines list; on screen the build-up still plays as drawn.
    public static func mergingBuildUps(_ sorted: [(start: Double, end: Double, text: String)],
                                       gap: Double = 0.5) -> [(start: Double, end: Double, text: String)] {
        var merged: [(start: Double, end: Double, text: String)] = []
        for line in sorted {
            if let last = merged.last, line.start - last.end < gap, line.start >= last.start,
               compact(line.text).hasPrefix(compact(last.text)) {
                merged[merged.count - 1] = (last.start, max(last.end, line.end), line.text)
            } else {
                merged.append(line)
            }
        }
        return merged
    }

    /// Text without spaces or line breaks, to compare lines.
    static func compact(_ text: String) -> String {
        text.filter { !$0.isWhitespace }
    }
}

public struct TranscriptStore: Sendable {
    public let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    /// Saves a transcript, replacing any earlier copy of the same item.
    public func save(_ info: TranscriptInfo, lines: [(start: Double, end: Double, text: String)]) throws {
        try database.writer.write { db in
            try db.execute(sql: "DELETE FROM transcriptLine WHERE itemId = ?", arguments: [info.itemId])
            try info.save(db)
            let statement = try db.makeStatement(sql: #"INSERT INTO transcriptLine (text, itemId, cue, start, "end") VALUES (?, ?, ?, ?, ?)"#)
            for (cue, line) in lines.enumerated() {
                try statement.execute(arguments: [line.text, info.itemId, cue, line.start, line.end])
            }
        }
    }

    public func transcript(itemId: String) throws -> TranscriptInfo? {
        try database.reader.read { try TranscriptInfo.fetchOne($0, key: itemId) }
    }

    /// Item ids with a saved transcript (for list badges).
    public func savedItemIds() throws -> Set<String> {
        try database.reader.read { Set(try String.fetchAll($0, sql: "SELECT itemId FROM transcript")) }
    }

    /// Saved transcripts, most recently played first (the Lines list when offline).
    public func recent(limit: Int = 200) throws -> [TranscriptInfo] {
        try database.reader.read { db in
            try TranscriptInfo.fetchAll(db, sql: "SELECT * FROM transcript ORDER BY COALESCE(lastPlayedAt, savedAt) DESC LIMIT ?",
                                        arguments: [limit])
        }
    }

    public func lines(itemId: String) throws -> [TranscriptLine] {
        try database.reader.read { db in
            try Row.fetchAll(db, sql: #"SELECT text, itemId, cue, start, "end" FROM transcriptLine WHERE itemId = ? ORDER BY cue"#,
                             arguments: [itemId]).map(Self.line)
        }
    }

    /// Records that an item was played again (keeps the list order right offline).
    public func touch(itemId: String, at date: Date) throws {
        try database.writer.write { db in
            try db.execute(sql: "UPDATE transcript SET lastPlayedAt = ? WHERE itemId = ?", arguments: [date, itemId])
        }
    }

    /// Lines containing `query`, grouped by episode (most recently played first).
    /// Three or more characters use the trigram index; shorter queries (many Japanese
    /// words are one or two characters) scan with LIKE.
    public func search(_ query: String, limit: Int = 300) throws -> [TranscriptSearchGroup] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        return try database.reader.read { db in
            let rows: [Row]
            if query.count >= 3 {
                let phrase = "\"" + query.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                rows = try Row.fetchAll(db, sql: #"SELECT text, itemId, cue, start, "end" FROM transcriptLine WHERE transcriptLine MATCH ? LIMIT ?"#,
                                        arguments: [phrase, limit])
            } else {
                let escaped = query.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
                rows = try Row.fetchAll(db, sql: #"SELECT text, itemId, cue, start, "end" FROM transcriptLine WHERE text LIKE ? ESCAPE '\' LIMIT ?"#,
                                        arguments: ["%\(escaped)%", limit])
            }
            let lines = rows.map(Self.line)
            let infos = try TranscriptInfo.fetchAll(db, keys: Set(lines.map(\.itemId)))
            return infos
                .sorted { ($0.lastPlayedAt ?? $0.savedAt) > ($1.lastPlayedAt ?? $1.savedAt) }
                .map { info in
                    TranscriptSearchGroup(transcript: info, lines: lines.filter { $0.itemId == info.itemId }.sorted { $0.cue < $1.cue })
                }
        }
    }

    /// Roughly how much space saved transcripts take, index included.
    public func approximateBytes() throws -> Int {
        try database.reader.read { db in
            // Trigram indexes run about three times the text itself.
            let text = try Int.fetchOne(db, sql: "SELECT COALESCE(SUM(length(CAST(text AS BLOB))), 0) FROM transcriptLine") ?? 0
            return text * 4
        }
    }

    public func clear() throws {
        try database.writer.write { db in
            try db.execute(sql: "DELETE FROM transcriptLine")
            try db.execute(sql: "DELETE FROM transcript")
        }
    }

    private static func line(_ row: Row) -> TranscriptLine {
        TranscriptLine(itemId: row["itemId"], cue: row["cue"], start: row["start"], end: row["end"], text: row["text"])
    }
}

/// A subtitle file for a Jellyfin item from somewhere else (e.g. Jimaku), kept as downloaded.
/// `offset` (seconds, positive = later) is the user's timing fix for their release. Nothing
/// goes to Jellyfin until the user saves it there.
public struct LocalSubtitle: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "localSubtitle"

    public var itemId: String
    public var source: String
    public var fileName: String
    /// "srt", "ass" or "ssa".
    public var format: String
    /// The file in use: as downloaded, or retimed by a sync.
    public var data: Data
    public var offset: Double
    public var savedAt: Date
    /// When Jellyfin last received a file for this item from the app (nil until then; kept
    /// when a new file is picked, since the old one is still on the server).
    public var uploadedAt: Date?
    /// The file as downloaded, once a sync has rewritten `data`.
    public var originalData: Data?
    /// When the timing or file last changed.
    public var editedAt: Date?
    /// When the user last asked to save it to Jellyfin.
    public var queuedAt: Date?
    /// For a copy of a Jellyfin track (`source` "jellyfin"): its stream index, and its file on
    /// the server when it's a separate file (saving then replaces that file).
    public var serverIndex: Int?
    public var serverPath: String?

    public init(itemId: String, source: String, fileName: String, format: String, data: Data, offset: Double = 0,
                savedAt: Date, uploadedAt: Date? = nil, originalData: Data? = nil, editedAt: Date? = nil, queuedAt: Date? = nil,
                serverIndex: Int? = nil, serverPath: String? = nil) {
        self.itemId = itemId
        self.source = source
        self.fileName = fileName
        self.format = format
        self.data = data
        self.offset = offset
        self.savedAt = savedAt
        self.uploadedAt = uploadedAt
        self.originalData = originalData
        self.editedAt = editedAt
        self.queuedAt = queuedAt
        self.serverIndex = serverIndex
        self.serverPath = serverPath
    }

    /// A copy of the server's own subtitles (retimed here), not a file from elsewhere.
    public var isServerCopy: Bool { source == "jellyfin" }

    /// Where this version stands with Jellyfin.
    public enum ServerState: Equatable, Sendable {
        /// Never saved there.
        case notSaved
        /// Saved earlier, but this version (a new file or new timing) isn't.
        case olderSaved
        /// Waiting in the outbox.
        case queued
        case saved
    }

    public var serverState: ServerState {
        let changed = max(savedAt, editedAt ?? savedAt)
        if let queuedAt, queuedAt >= changed {
            if let uploadedAt, uploadedAt >= queuedAt { return .saved }
            return .queued
        }
        return uploadedAt == nil ? .notSaved : .olderSaved
    }
}

public struct LocalSubtitleStore: Sendable {
    public let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func subtitle(itemId: String) throws -> LocalSubtitle? {
        try database.reader.read { try LocalSubtitle.fetchOne($0, key: itemId) }
    }

    /// Saves a newly picked file, replacing the item's previous one (whose upload time is
    /// kept: that file is still on the server).
    public func save(_ subtitle: LocalSubtitle) throws {
        try database.writer.write { db in
            var subtitle = subtitle
            if subtitle.uploadedAt == nil {
                subtitle.uploadedAt = try LocalSubtitle.fetchOne(db, key: subtitle.itemId)?.uploadedAt
            }
            try subtitle.save(db)
        }
    }

    public func setOffset(_ offset: Double, itemId: String, at date: Date = Date()) throws {
        try database.writer.write { db in
            try db.execute(sql: "UPDATE localSubtitle SET offset = ?, editedAt = ? WHERE itemId = ?",
                           arguments: [offset, date, itemId])
        }
    }

    /// Replaces the file with a retimed one (timing offset back to zero), keeping the
    /// downloaded file for `restoreOriginal`.
    public func saveSynced(_ data: Data, itemId: String, at date: Date = Date()) throws {
        try database.writer.write { db in
            try db.execute(sql: """
                UPDATE localSubtitle SET originalData = COALESCE(originalData, data), data = ?, offset = 0, editedAt = ?
                WHERE itemId = ?
                """, arguments: [data, date, itemId])
        }
    }

    /// Back to the file as downloaded, with no timing fix.
    public func restoreOriginal(itemId: String, at date: Date = Date()) throws {
        try database.writer.write { db in
            try db.execute(sql: """
                UPDATE localSubtitle SET data = COALESCE(originalData, data), originalData = NULL, offset = 0, editedAt = ?
                WHERE itemId = ?
                """, arguments: [date, itemId])
        }
    }

    public func markQueued(itemId: String, at date: Date) throws {
        try database.writer.write { db in
            try db.execute(sql: "UPDATE localSubtitle SET queuedAt = ? WHERE itemId = ?", arguments: [date, itemId])
        }
    }

    public func markUploaded(itemId: String, at date: Date) throws {
        try database.writer.write { db in
            try db.execute(sql: "UPDATE localSubtitle SET uploadedAt = ? WHERE itemId = ?", arguments: [date, itemId])
        }
    }
}
