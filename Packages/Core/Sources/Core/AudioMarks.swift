import Foundation
import GRDB

/// "What I just heard" in a podcast episode (Kiku's mark now, mine later): the episode and
/// the playback position when the mark was made. The audio and lines come from the episode.
public struct AudioMark: Codable, Equatable, Hashable, Sendable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "audioMark"

    /// How the mark was made, shown on it.
    public enum Source: String, Codable, Sendable {
        /// `nowPlaying` was Now Playing's bookmark, tried in milestone 3: iOS 26 doesn't show it.
        /// `headphones` is an AirPods triple press (or a car's previous-track button).
        case player, shortcut, nowPlaying, headphones
    }

    public var id: Int64?
    public var itemId: String
    public var episodeId: String
    public var showTitle: String
    public var episodeTitle: String
    /// The playback position when marked, in seconds.
    public var time: Double
    public var createdAt: Date
    public var source: Source
    /// Set when a card is mined from the mark (it shows "Mined …" for a day, then goes).
    public var minedAt: Date?
    public var minedWord: String?
    public var minedJobId: Int64?

    public init(itemId: String, episodeId: String, showTitle: String, episodeTitle: String, time: Double,
                createdAt: Date, source: Source) {
        self.itemId = itemId
        self.episodeId = episodeId
        self.showTitle = showTitle
        self.episodeTitle = episodeTitle
        self.time = time
        self.createdAt = createdAt
        self.source = source
    }

    /// The episode key ("<item>/<episode>") transcripts, downloads and progress use.
    public var key: String { AudioTranscriptInfo.key(itemId: itemId, episodeId: episodeId) }
    public var isMined: Bool { minedAt != nil }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

public struct AudioMarkStore: Sendable {
    let database: AppDatabase
    let now: @Sendable () -> Date

    /// Mined marks stay visible this long.
    public static let minedKeptFor: TimeInterval = 24 * 60 * 60

    public init(database: AppDatabase, now: @escaping @Sendable () -> Date = Date.init) {
        self.database = database
        self.now = now
    }

    @discardableResult
    public func add(_ mark: AudioMark) throws -> AudioMark {
        try database.writer.write { db in
            var mark = mark
            try mark.insert(db)
            return mark
        }
    }

    /// Marks to show, newest first: mined ones only for a day.
    public func marks() throws -> [AudioMark] {
        try database.reader.read { try Self.visible($0, now: now()) }
    }

    /// The marks as they change (deletes mined marks older than a day first).
    public func observe() -> AsyncThrowingStream<[AudioMark], any Error> {
        try? pruneMined()
        let now = now
        return database.values { try Self.visible($0, now: now()) }
    }

    /// Clear: dismisses a mark without mining it.
    public func remove(_ id: Int64) throws {
        _ = try database.writer.write { try AudioMark.deleteOne($0, key: id) }
    }

    public func setMined(_ id: Int64, word: String, jobId: Int64?) throws {
        let date = now()
        try database.writer.write { db in
            try db.execute(sql: "UPDATE audioMark SET minedAt = ?, minedWord = ?, minedJobId = ? WHERE id = ?",
                           arguments: [date, word, jobId, id])
        }
    }

    /// Undo of the card mined from a mark: the mark is waiting again.
    public func setUnmined(jobId: Int64) throws {
        try database.writer.write { db in
            try db.execute(sql: "UPDATE audioMark SET minedAt = NULL, minedWord = NULL, minedJobId = NULL WHERE minedJobId = ?",
                           arguments: [jobId])
        }
    }

    public func pruneMined() throws {
        let cutoff = now().addingTimeInterval(-Self.minedKeptFor)
        try database.writer.write { db in
            try db.execute(sql: "DELETE FROM audioMark WHERE minedAt IS NOT NULL AND minedAt < ?", arguments: [cutoff])
        }
    }

    private static func visible(_ db: Database, now: Date) throws -> [AudioMark] {
        try AudioMark
            .filter(Column("minedAt") == nil || Column("minedAt") >= now.addingTimeInterval(-minedKeptFor))
            .order(Column("createdAt").desc)
            .fetchAll(db)
    }
}
