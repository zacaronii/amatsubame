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
