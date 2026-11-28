import Foundation
import GRDB

/// Kiku's list of what goes on Apple Watch: each item's key and its encoded `WatchItem` (from
/// KikuWatchLink), oldest first. The phone sends the whole list to the watch on every change.
public struct KikuWatchItemStore: Sendable {
    let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func all() throws -> [(key: String, item: Data)] {
        try database.reader.read { db in
            try Row.fetchAll(db, sql: "SELECT key, item FROM kikuWatchItem ORDER BY addedAt, key").map { ($0["key"], $0["item"]) }
        }
    }

    public func save(key: String, item: Data, addedAt: Date = Date()) throws {
        try database.writer.write {
            try $0.execute(sql: "INSERT OR REPLACE INTO kikuWatchItem (key, item, addedAt) VALUES (?, ?, ?)", arguments: [key, item, addedAt])
        }
    }

    public func remove(_ key: String) throws {
        try database.writer.write { try $0.execute(sql: "DELETE FROM kikuWatchItem WHERE key = ?", arguments: [key]) }
    }

    public func removeAll() throws {
        try database.writer.write { try $0.execute(sql: "DELETE FROM kikuWatchItem") }
    }

    /// The keys, kept current.
    public func observeKeys() -> AsyncThrowingStream<[String], any Error> {
        database.values { try String.fetchAll($0, sql: "SELECT key FROM kikuWatchItem ORDER BY addedAt, key") }
    }
}

/// Listening on Apple Watch that Kiku applied (Stats, Audiobookshelf), by the watch's id.
public struct KikuWatchListeningStore: Sendable {
    let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    /// The version applied: its seconds and when it ended.
    public func applied(_ id: String) throws -> (seconds: Double, endedAt: Date)? {
        try database.reader.read { db in
            try Row.fetchOne(db, sql: "SELECT seconds, endedAt FROM kikuWatchListening WHERE id = ?", arguments: [id])
                .map { ($0["seconds"], $0["endedAt"]) }
        }
    }

    public func markApplied(_ id: String, seconds: Double, endedAt: Date, at date: Date = Date()) throws {
        try database.writer.write {
            try $0.execute(sql: "INSERT OR REPLACE INTO kikuWatchListening (id, seconds, endedAt, appliedAt) VALUES (?, ?, ?, ?)",
                           arguments: [id, seconds, endedAt, date])
        }
    }

    /// The latest applied, id → end, for the watch to drop what's done.
    public func recent(limit: Int = 300) throws -> [String: Date] {
        try database.reader.read { db in
            Dictionary(try Row.fetchAll(db, sql: "SELECT id, endedAt FROM kikuWatchListening ORDER BY appliedAt DESC LIMIT ?", arguments: [limit])
                .map { ($0["id"], $0["endedAt"]) }, uniquingKeysWith: { first, _ in first })
        }
    }

    /// When listening from the watch last arrived.
    public func lastAppliedAt() throws -> Date? {
        try database.reader.read { try Date.fetchOne($0, sql: "SELECT MAX(appliedAt) FROM kikuWatchListening") }
    }
}

/// Kiku's automatic rules for Apple Watch (milestone 4), built from the phone's automatic
/// download lists. Off unless turned on.
public struct KikuWatchRules: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "kikuWatchRules"
    var id = 1
    /// Sync to Watch Once Started: what you start playing on the phone goes to the watch too.
    public var onceStarted = false
    /// The first this many of each show's download ahead (0: off; 1 to 5).
    public var ahead = 0
    /// Removes an episode or book from the watch a day after it's finished.
    public var removesPlayed = false
    /// With `removesPlayed`, what you sent by hand stays.
    public var keepsManual = true
    /// Bytes the rules may fill on the watch (0: no limit); what you send by hand still goes.
    public var storageLimit: Int64 = 0

    public static let aheadChoices = [0, 1, 2, 3, 4, 5]
    public static let storageChoices: [Int64] = [0, 1, 2, 4, 8, 16].map { $0 * 1_000_000_000 }

    public init(onceStarted: Bool = false, ahead: Int = 0, removesPlayed: Bool = false, keepsManual: Bool = true, storageLimit: Int64 = 0) {
        self.onceStarted = onceStarted
        self.ahead = ahead
        self.removesPlayed = removesPlayed
        self.keepsManual = keepsManual
        self.storageLimit = storageLimit
    }

    public var isOn: Bool { onceStarted || ahead > 0 || removesPlayed }

    public static func load(_ database: AppDatabase) -> KikuWatchRules {
        (try? database.reader.read { try KikuWatchRules.fetchOne($0, key: 1) }) ?? KikuWatchRules()
    }

    public func save(_ database: AppDatabase) throws {
        try database.writer.write { try self.save($0) }
    }
}

/// Automatic items removed from the watch (there or on the phone), by key: the rules leave them off.
public struct KikuWatchDeclinedStore: Sendable {
    let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func all() throws -> Set<String> {
        try database.reader.read { Set(try String.fetchAll($0, sql: "SELECT key FROM kikuWatchDeclined")) }
    }

    public func decline(_ key: String, at date: Date = Date()) throws {
        try database.writer.write {
            try $0.execute(sql: "INSERT OR REPLACE INTO kikuWatchDeclined (key, declinedAt) VALUES (?, ?)", arguments: [key, date])
        }
    }

    /// Sent again by hand: the rules may manage it again later.
    public func undecline(_ key: String) throws {
        try database.writer.write { try $0.execute(sql: "DELETE FROM kikuWatchDeclined WHERE key = ?", arguments: [key]) }
    }
}
