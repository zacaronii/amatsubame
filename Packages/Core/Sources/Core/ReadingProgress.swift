import Foundation
import GRDB

/// The last page shown on this device for a Kavita chapter. Written on every
/// page turn; the outbox carries it to the server.
public struct LocalReadingProgress: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "kavitaReadingProgress"

    public var chapterId: Int
    public var seriesId: Int
    public var volumeId: Int
    public var libraryId: Int
    /// 0-based index of the page on screen.
    public var page: Int
    public var pages: Int
    public var updatedAt: Date
    /// Where on the page, for books: Kavita's `bookScrollId` (an XPath).
    public var scrollId: String?
    /// Characters read in the volume, for books: the reader's own count, so the series page
    /// can show the same percentage as the reader.
    public var characters: Int?

    public init(
        chapterId: Int, seriesId: Int, volumeId: Int, libraryId: Int, page: Int, pages: Int, updatedAt: Date, scrollId: String? = nil,
        characters: Int? = nil
    ) {
        self.chapterId = chapterId
        self.seriesId = seriesId
        self.volumeId = volumeId
        self.libraryId = libraryId
        self.page = page
        self.pages = pages
        self.updatedAt = updatedAt
        self.scrollId = scrollId
        self.characters = characters
    }
}

extension LocalReadingProgress {
    /// Kavita counts pages read: the page on screen, except that reaching the last page counts
    /// all `pages`, which is what marks the chapter read.
    public static func pagesRead(forPage page: Int, pages: Int) -> Int {
        guard pages > 0 else { return 0 }
        return page >= pages - 1 ? pages : max(page, 0)
    }

    /// This row as Kavita's pages read.
    public var pagesRead: Int { Self.pagesRead(forPage: page, pages: pages) }

    /// The one rule for a chapter's pages read shown anywhere (the series page, a reading list):
    /// Kavita's count with this device's own where it's ahead of what Kavita knows (read offline,
    /// or not sent yet). This device's count wins outright when it was saved after Kavita's date
    /// for the chapter (so Mark as Unread shows before Kavita has it); without dates, a chapter
    /// only ever moves on.
    public static func pagesRead(kavita: Int, kavitaAt: Date?, local: Int, localAt: Date?, pages: Int) -> Int {
        let local = min(local, pages)
        if let localAt, let kavitaAt, localAt > kavitaAt { return local }
        return max(kavita, local)
    }
}

public struct ReadingProgressStore: Sendable {
    public let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func progress(chapterId: Int) throws -> LocalReadingProgress? {
        try database.reader.read { try LocalReadingProgress.fetchOne($0, key: chapterId) }
    }

    /// Every chapter of a series read on this device.
    public func progress(seriesId: Int) throws -> [LocalReadingProgress] {
        try database.reader.read { try LocalReadingProgress.filter(Column("seriesId") == seriesId).fetchAll($0) }
    }

    public func save(_ progress: LocalReadingProgress) throws {
        try database.writer.write { try progress.save($0) }
    }

    /// Most recently read chapters, one per series, for the offline Continue Reading shelf.
    public func recentlyRead(limit: Int = 20) throws -> [LocalReadingProgress] {
        try database.reader.read { db in
            try LocalReadingProgress.fetchAll(db, sql: """
                SELECT p.* FROM kavitaReadingProgress p
                WHERE p.updatedAt = (SELECT MAX(updatedAt) FROM kavitaReadingProgress WHERE seriesId = p.seriesId)
                ORDER BY p.updatedAt DESC LIMIT ?
                """, arguments: [limit])
        }
    }
}
