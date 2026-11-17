import Foundation
import GRDB

/// A series, show, movie or book pinned to the Mac's sidebar. Each app keeps its own.
public struct PinnedItem: Codable, FetchableRecord, PersistableRecord, Identifiable, Hashable, Sendable {
    public static let databaseTableName = "pinnedItem"

    /// The server's id for it.
    public var id: String
    /// What it is, in the app's own words ("series", "movie", "show", "book"): which page opens.
    public var kind: String
    public var title: String
    public var pinnedAt: Date

    public init(id: String, kind: String, title: String, pinnedAt: Date = Date()) {
        self.id = id
        self.kind = kind
        self.title = title
        self.pinnedAt = pinnedAt
    }
}

public struct PinStore: Sendable {
    public let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    /// Oldest first, so a new pin goes to the bottom.
    public func all() throws -> [PinnedItem] {
        try database.reader.read { try PinnedItem.order(Column("pinnedAt"), Column("id")).fetchAll($0) }
    }

    /// Pins it, or updates its title if it's pinned already (keeping its place).
    public func pin(_ item: PinnedItem) throws {
        try database.writer.write { db in
            if var existing = try PinnedItem.fetchOne(db, key: item.id) {
                existing.title = item.title
                try existing.update(db)
            } else {
                try item.insert(db)
            }
        }
    }

    public func unpin(id: String) throws {
        _ = try database.writer.write { try PinnedItem.deleteOne($0, key: id) }
    }
}
