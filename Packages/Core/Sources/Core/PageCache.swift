import Foundation
import GRDB

/// Identifies one cached page image (or per-chapter metadata, using a negative page).
public struct PageCacheKey: Hashable, Sendable, CustomStringConvertible {
    public var chapterId: Int
    public var page: Int

    public init(chapterId: Int, page: Int) {
        self.chapterId = chapterId
        self.page = page
    }

    /// Page dimensions for a chapter, cached so the reader can lay out offline.
    public static func dimensions(chapterId: Int) -> PageCacheKey {
        PageCacheKey(chapterId: chapterId, page: -1)
    }

    public var description: String { "kavita.\(chapterId).\(page)" }
}

struct PageCacheEntry: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "pageCache"
    var key: String
    var chapterId: Int
    var page: Int
    var filename: String
    var bytes: Int
    var lastAccessAt: Date
    var pinned: Bool
}

/// Disk cache for page images with an LRU index in SQLite. Pinned entries
/// (downloaded volumes) are never evicted or cleared.
public struct PageCacheStore: Sendable {
    public static let defaultLimit = 1024 * 1024 * 1024

    public let database: AppDatabase
    public let directory: URL
    public let limitBytes: Int
    public let now: @Sendable () -> Date

    public init(
        database: AppDatabase,
        directory: URL,
        limitBytes: Int = PageCacheStore.defaultLimit,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.database = database
        self.directory = directory
        self.limitBytes = limitBytes
        self.now = now
    }

    private func fileURL(_ filename: String) -> URL {
        directory.appending(path: filename)
    }

    /// Returns cached data and marks it recently used. Drops index rows whose file vanished.
    public func data(for key: PageCacheKey) -> Data? {
        let id = key.description
        guard let entry = try? database.reader.read({ try PageCacheEntry.fetchOne($0, key: id) }) else { return nil }
        guard let data = try? Data(contentsOf: fileURL(entry.filename)) else {
            _ = try? database.writer.write { try PageCacheEntry.deleteOne($0, key: id) }
            return nil
        }
        let now = now()
        try? database.writer.write { db in
            try db.execute(sql: "UPDATE pageCache SET lastAccessAt = ? WHERE key = ?", arguments: [now, id])
        }
        return data
    }

    public func contains(_ key: PageCacheKey) -> Bool {
        (try? database.reader.read { try PageCacheEntry.exists($0, key: key.description) }) ?? false
    }

    public func store(_ data: Data, for key: PageCacheKey, pinned: Bool = false) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let filename = "\(key.chapterId)-\(key.page).bin"
        try data.write(to: fileURL(filename), options: .atomic)
        let now = now()
        try database.writer.write { db in
            // Re-storing a downloaded page keeps it downloaded.
            let wasPinned = try Bool.fetchOne(db, sql: "SELECT pinned FROM pageCache WHERE key = ?", arguments: [key.description]) ?? false
            let entry = PageCacheEntry(
                key: key.description, chapterId: key.chapterId, page: key.page, filename: filename,
                bytes: data.count, lastAccessAt: now, pinned: pinned || wasPinned
            )
            try entry.save(db)
        }
        try evictIfNeeded()
    }

    /// Deletes least recently used unpinned entries until the unpinned total fits the limit.
    public func evictIfNeeded() throws {
        let doomed: [PageCacheEntry] = try database.writer.write { db in
            var total = try Int.fetchOne(db, sql: "SELECT COALESCE(SUM(bytes), 0) FROM pageCache WHERE pinned = 0") ?? 0
            guard total > limitBytes else { return [] }
            var doomed: [PageCacheEntry] = []
            let cursor = try PageCacheEntry
                .filter(Column("pinned") == false)
                .order(Column("lastAccessAt"), Column("key"))
                .fetchCursor(db)
            while total > limitBytes, let entry = try cursor.next() {
                doomed.append(entry)
                total -= entry.bytes
            }
            _ = try PageCacheEntry.deleteAll(db, keys: doomed.map(\.key))
            return doomed
        }
        for entry in doomed {
            try? FileManager.default.removeItem(at: fileURL(entry.filename))
        }
    }

    public func totalBytes() throws -> Int {
        try database.reader.read { db in
            try Int.fetchOne(db, sql: "SELECT COALESCE(SUM(bytes), 0) FROM pageCache") ?? 0
        }
    }

    /// Bytes of cached pages that aren't downloads (what "Clear" would free).
    public func unpinnedBytes() throws -> Int {
        try database.reader.read { db in
            try Int.fetchOne(db, sql: "SELECT COALESCE(SUM(bytes), 0) FROM pageCache WHERE pinned = 0") ?? 0
        }
    }

    /// Bytes stored for one chapter (pages and metadata).
    public func bytes(chapterId: Int) throws -> Int {
        try database.reader.read { db in
            try Int.fetchOne(db, sql: "SELECT COALESCE(SUM(bytes), 0) FROM pageCache WHERE chapterId = ?", arguments: [chapterId]) ?? 0
        }
    }

    /// Pages of a chapter already on the device (metadata entries excluded).
    public func cachedPages(chapterId: Int) throws -> Set<Int> {
        try database.reader.read { db in
            Set(try Int.fetchAll(db, sql: "SELECT page FROM pageCache WHERE chapterId = ? AND page >= 0", arguments: [chapterId]))
        }
    }

    /// Marks a chapter's cached entries as downloaded (never evicted) or back to ordinary cache.
    public func setPinned(chapterId: Int, _ pinned: Bool) throws {
        try database.writer.write { db in
            try db.execute(sql: "UPDATE pageCache SET pinned = ? WHERE chapterId = ?", arguments: [pinned, chapterId])
        }
        if !pinned { try evictIfNeeded() }
    }

    /// Deletes a chapter's entries, downloaded or not.
    public func remove(chapterId: Int) throws {
        let doomed: [PageCacheEntry] = try database.writer.write { db in
            let entries = try PageCacheEntry.filter(Column("chapterId") == chapterId).fetchAll(db)
            _ = try PageCacheEntry.filter(Column("chapterId") == chapterId).deleteAll(db)
            return entries
        }
        for entry in doomed {
            try? FileManager.default.removeItem(at: fileURL(entry.filename))
        }
    }

    /// Removes every unpinned entry.
    public func clear() throws {
        let doomed: [PageCacheEntry] = try database.writer.write { db in
            let entries = try PageCacheEntry.filter(Column("pinned") == false).fetchAll(db)
            _ = try PageCacheEntry.filter(Column("pinned") == false).deleteAll(db)
            return entries
        }
        for entry in doomed {
            try? FileManager.default.removeItem(at: fileURL(entry.filename))
        }
    }
}
