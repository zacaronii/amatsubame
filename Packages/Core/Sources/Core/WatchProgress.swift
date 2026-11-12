import Foundation
import GRDB

/// The last position played on this device for a Jellyfin item, in seconds. Written
/// while playing; the outbox carries it to the server.
public struct LocalWatchProgress: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "watchProgress"

    public var itemId: String
    public var seriesId: String?
    public var position: Double
    public var duration: Double
    public var updatedAt: Date

    public init(itemId: String, seriesId: String?, position: Double, duration: Double, updatedAt: Date) {
        self.itemId = itemId
        self.seriesId = seriesId
        self.position = position
        self.duration = duration
        self.updatedAt = updatedAt
    }

    /// Where to start: the server's position unless this device played it more recently.
    /// Near the end counts as finished and starts over.
    public static func resumePosition(local: LocalWatchProgress?, server: Double?, serverDate: Date?) -> Double {
        var position = server ?? 0
        if let local, serverDate.map({ local.updatedAt > $0 }) ?? true {
            position = local.position
            if local.duration > 0 && local.duration - local.position < 30 { position = 0 }
        }
        return position
    }
}

public struct WatchProgressStore: Sendable {
    public let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func progress(itemId: String) throws -> LocalWatchProgress? {
        try database.reader.read { try LocalWatchProgress.fetchOne($0, key: itemId) }
    }

    public func save(_ progress: LocalWatchProgress) throws {
        try database.writer.write { try progress.save($0) }
    }
}

/// Jellyfin libraries turned off in Settings → Libraries.
public struct JellyfinLibraryVisibilityStore: Sendable {
    public let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func setHidden(_ libraryId: String, hidden: Bool) throws {
        try database.writer.write { db in
            if hidden {
                try db.execute(sql: "INSERT OR IGNORE INTO hiddenJellyfinLibrary (libraryId) VALUES (?)", arguments: [libraryId])
            } else {
                try db.execute(sql: "DELETE FROM hiddenJellyfinLibrary WHERE libraryId = ?", arguments: [libraryId])
            }
        }
    }

    public func observeHidden() -> AsyncThrowingStream<Set<String>, any Error> {
        database.values { Set(try String.fetchAll($0, sql: "SELECT libraryId FROM hiddenJellyfinLibrary")) }
    }

    /// Libraries that show only movies and shows with a Japanese audio track.
    public func setJapaneseOnly(_ libraryId: String, _ on: Bool) throws {
        try database.writer.write { db in
            if on {
                try db.execute(sql: "INSERT OR IGNORE INTO japaneseOnlyJellyfinLibrary (libraryId) VALUES (?)", arguments: [libraryId])
            } else {
                try db.execute(sql: "DELETE FROM japaneseOnlyJellyfinLibrary WHERE libraryId = ?", arguments: [libraryId])
            }
        }
    }

    public func observeJapaneseOnly() -> AsyncThrowingStream<Set<String>, any Error> {
        database.values { Set(try String.fetchAll($0, sql: "SELECT libraryId FROM japaneseOnlyJellyfinLibrary")) }
    }
}

/// Whether a series has Japanese audio, from one of its episodes (series items carry no streams).
public struct JellyfinAudioCheck: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "jellyfinAudioCheck"

    public var itemId: String
    public var hasJapanese: Bool
    public var checkedAt: Date

    public init(itemId: String, hasJapanese: Bool, checkedAt: Date = .now) {
        self.itemId = itemId
        self.hasJapanese = hasJapanese
        self.checkedAt = checkedAt
    }
}

public struct JellyfinAudioCheckStore: Sendable {
    /// Answers are checked again after this long (a dub may be added later).
    public static let maxAge: TimeInterval = 30 * 24 * 3600
    public let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    /// The saved answers for `itemIds` that aren't older than `maxAge`.
    public func answers(for itemIds: [String], now: Date = .now) throws -> [String: Bool] {
        let checks = try database.reader.read { try JellyfinAudioCheck.fetchAll($0, keys: itemIds) }
        return Dictionary(checks.filter { now.timeIntervalSince($0.checkedAt) < Self.maxAge }.map { ($0.itemId, $0.hasJapanese) },
                          uniquingKeysWith: { first, _ in first })
    }

    public func save(_ checks: [JellyfinAudioCheck]) throws {
        try database.writer.write { db in
            for check in checks { try check.save(db) }
        }
    }
}

/// A saved part of a Jellyfin item (intro, credits…), in seconds. `kind` is Jellyfin's name.
public struct CachedMediaSegment: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "mediaSegment"

    public var itemId: String
    public var kind: String
    public var start: Double
    public var end: Double

    public init(itemId: String, kind: String, start: Double, end: Double) {
        self.itemId = itemId
        self.kind = kind
        self.start = start
        self.end = end
    }
}

public struct MediaSegmentStore: Sendable {
    public let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func segments(itemId: String) throws -> [CachedMediaSegment] {
        try database.reader.read { db in
            try CachedMediaSegment.filter(Column("itemId") == itemId).order(Column("start")).fetchAll(db)
        }
    }

    /// Replaces what's saved for the item (the server's list is the truth).
    public func save(_ segments: [CachedMediaSegment], itemId: String) throws {
        try database.writer.write { db in
            try CachedMediaSegment.filter(Column("itemId") == itemId).deleteAll(db)
            for segment in segments { try segment.insert(db) }
        }
    }
}

/// The Player's playback settings.
public struct PlayerSettings: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "playerSettings"
    var id = 1
    /// Intros (and recaps) are skipped without tapping the button.
    public var autoSkipsIntros = false
    /// What a mined card's picture is: a still frame or the line as an animated GIF.
    public var cardPicture = CardPicture.screenshot

    public enum CardPicture: String, Codable, CaseIterable, Sendable {
        case screenshot, animated
    }

    public init(autoSkipsIntros: Bool = false, cardPicture: CardPicture = .screenshot) {
        self.autoSkipsIntros = autoSkipsIntros
        self.cardPicture = cardPicture
    }

    public static func load(_ database: AppDatabase) -> PlayerSettings {
        (try? database.reader.read { try PlayerSettings.fetchOne($0, key: 1) }) ?? PlayerSettings()
    }

    public func save(_ database: AppDatabase) throws {
        try database.writer.write { try self.save($0) }
    }
}
