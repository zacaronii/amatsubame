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
    /// What a mined card's picture is: a still frame or the line as an animated GIF. New setups
    /// start animated; a saved choice (the column's default for older rows: a still) stays.
    public var cardPicture = CardPicture.animated
    /// The playback speed last chosen (1 = normal), kept from one video to the next.
    public var speed = 1.0
    /// Pause at the end of every Japanese line (intensive listening), until play is pressed.
    public var pausesAfterLines = false
    /// The Japanese subtitles' size (1 = sized to the picture) and how far up from the bottom
    /// they sit (a fraction of the picture's height, to clear burnt-in subtitles).
    public var subtitleScale = 1.0
    public var subtitleLift = 0.0
    /// The Japanese line is blurred until it's tapped (or pointed at): listening first.
    public var concealsSubtitles = false
    /// On the Mac, playback pauses while the pointer rests on the subtitles.
    public var pausesOnHover = false
    /// The most bits a second to stream at: above it, Jellyfin transcodes the video down. 0 is
    /// the original file, whatever its size. Downloads always play as they are.
    public var maxStreamBitrate = 0

    public static let streamQualities: [(name: String, bitrate: Int)] = [
        ("Original", 0), ("8 Mbps", 8_000_000), ("4 Mbps", 4_000_000), ("2 Mbps", 2_000_000), ("1 Mbps", 1_000_000), ("0.5 Mbps", 500_000),
    ]

    /// The best quality a connection giving `speed` bits a second keeps up with, leaving some
    /// room; the lowest there is when even that's too much.
    public static func streamQuality(fitting speed: Double) -> Int {
        let limits = streamQualities.map(\.bitrate).filter { $0 > 0 }
        return limits.first { Double($0) <= speed * 0.8 } ?? limits.last ?? 0
    }

    public static let subtitleScales: [(name: String, scale: Double)] = [("Small", 0.8), ("Medium", 1), ("Large", 1.25), ("Extra Large", 1.5)]
    public static let subtitleLifts: [(name: String, lift: Double)] = [("Bottom", 0), ("Higher", 0.12), ("Highest", 0.25)]

    public enum CardPicture: String, Codable, CaseIterable, Sendable {
        case screenshot, animated
    }

    public init(autoSkipsIntros: Bool = false, cardPicture: CardPicture = .animated) {
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

/// One show's own player settings in Miru (by series id, or a movie's item id).
public struct SeriesPlayerSetting: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "seriesPlayerSetting"
    public var seriesKey: String
    /// Condensed playback: the stretches without a Japanese line are skipped.
    public var condensed = false

    public init(seriesKey: String, condensed: Bool = false) {
        self.seriesKey = seriesKey
        self.condensed = condensed
    }

    public static func load(_ database: AppDatabase, seriesKey: String) -> SeriesPlayerSetting {
        (try? database.reader.read { try SeriesPlayerSetting.fetchOne($0, key: seriesKey) }) ?? SeriesPlayerSetting(seriesKey: seriesKey)
    }

    /// Saved, or forgotten when it's back to the defaults.
    public func save(_ database: AppDatabase) throws {
        try database.writer.write { db in
            if condensed { try self.save(db) } else { _ = try SeriesPlayerSetting.deleteOne(db, key: seriesKey) }
        }
    }
}
