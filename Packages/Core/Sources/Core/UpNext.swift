import Foundation
import GRDB

/// An episode waiting in Kiku's Up Next.
public struct UpNextItem: Codable, Equatable, Hashable, Sendable {
    public var itemId: String
    public var episodeId: String
    public var title: String
    public var showTitle: String

    public init(itemId: String, episodeId: String, title: String, showTitle: String) {
        self.itemId = itemId
        self.episodeId = episodeId
        self.title = title
        self.showTitle = showTitle
    }

    /// The episode key ("<item>/<episode>") progress and downloads use.
    public var key: String { AudioTranscriptInfo.key(itemId: itemId, episodeId: episodeId) }
}

/// Kiku's Up Next per podcast library, as this device has it: Audiobookshelf's "Up Next"
/// playlist, with the changes made here that the outbox hasn't sent yet. Changes return the
/// whole new list, which the caller queues for the server.
public struct UpNextStore: Sendable {
    let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func items(libraryId: String) throws -> [UpNextItem] {
        try database.reader.read { try Self.items($0, libraryId: libraryId) }
    }

    /// Every library's queue, for the Listen screen.
    public func all() throws -> [String: [UpNextItem]] {
        try database.reader.read { db in
            let libraries = try String.fetchAll(db, sql: "SELECT DISTINCT libraryId FROM upNextItem")
            return try Dictionary(uniqueKeysWithValues: libraries.map { ($0, try Self.items(db, libraryId: $0)) })
        }
    }

    public func observe() -> AsyncThrowingStream<[String: [UpNextItem]], any Error> {
        database.values { db in
            let libraries = try String.fetchAll(db, sql: "SELECT DISTINCT libraryId FROM upNextItem")
            return try Dictionary(uniqueKeysWithValues: libraries.map { ($0, try Self.items(db, libraryId: $0)) })
        }
    }

    /// Replaces a library's queue (a change here, or what the server has).
    public func set(_ items: [UpNextItem], libraryId: String) throws {
        try database.writer.write { db in
            try db.execute(sql: "DELETE FROM upNextItem WHERE libraryId = ?", arguments: [libraryId])
            var seen = Set<String>()
            for (position, item) in items.enumerated() where seen.insert(item.key).inserted {
                try db.execute(sql: "INSERT INTO upNextItem (libraryId, position, itemId, episodeId, title, showTitle) VALUES (?, ?, ?, ?, ?, ?)",
                               arguments: [libraryId, position, item.itemId, item.episodeId, item.title, item.showTitle])
            }
        }
    }

    /// Play Next: to the top (moved there if it was further down).
    @discardableResult
    public func playNext(_ item: UpNextItem, libraryId: String) throws -> [UpNextItem] {
        let list = [item] + (try items(libraryId: libraryId)).filter { $0.key != item.key }
        try set(list, libraryId: libraryId)
        return list
    }

    /// Play Last: to the end (moved there if it was already queued).
    @discardableResult
    public func playLast(_ item: UpNextItem, libraryId: String) throws -> [UpNextItem] {
        let list = (try items(libraryId: libraryId)).filter { $0.key != item.key } + [item]
        try set(list, libraryId: libraryId)
        return list
    }

    /// Takes an episode out (removed, or started). Nil when it wasn't queued.
    @discardableResult
    public func remove(key: String, libraryId: String) throws -> [UpNextItem]? {
        let current = try items(libraryId: libraryId)
        guard current.contains(where: { $0.key == key }) else { return nil }
        let list = current.filter { $0.key != key }
        try set(list, libraryId: libraryId)
        return list
    }

    @discardableResult
    public func move(from source: IndexSet, to destination: Int, libraryId: String) throws -> [UpNextItem] {
        var list = try items(libraryId: libraryId)
        let moving = source.sorted().filter { list.indices.contains($0) }.map { list[$0] }
        for index in source.sorted(by: >) where list.indices.contains(index) { list.remove(at: index) }
        let before = source.filter { $0 < destination }.count
        list.insert(contentsOf: moving, at: min(max(destination - before, 0), list.count))
        try set(list, libraryId: libraryId)
        return list
    }

    public func playlistId(libraryId: String) throws -> String? {
        try database.reader.read {
            try String.fetchOne($0, sql: "SELECT playlistId FROM upNextPlaylist WHERE libraryId = ?", arguments: [libraryId])
        }
    }

    public func setPlaylistId(_ id: String?, libraryId: String) throws {
        try database.writer.write {
            try $0.execute(sql: "INSERT INTO upNextPlaylist (libraryId, playlistId) VALUES (?, ?) ON CONFLICT(libraryId) DO UPDATE SET playlistId = excluded.playlistId",
                           arguments: [libraryId, id])
        }
    }

    static func items(_ db: Database, libraryId: String) throws -> [UpNextItem] {
        try Row.fetchAll(db, sql: "SELECT itemId, episodeId, title, showTitle FROM upNextItem WHERE libraryId = ? ORDER BY position",
                         arguments: [libraryId]).map {
            UpNextItem(itemId: $0["itemId"], episodeId: $0["episodeId"], title: $0["title"], showTitle: $0["showTitle"])
        }
    }
}
