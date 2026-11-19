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
