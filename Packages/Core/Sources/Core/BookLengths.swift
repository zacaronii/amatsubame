import Foundation
import GRDB

/// Yomu: how many characters an EPUB volume (Kavita chapter) holds, section by section, as
/// Hoshi Reader counts them. Counted from the book when it's opened, or from Kavita's text by
/// the character counter; kept apart from the book's files, so it stays when they're removed.
public struct BookLength: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "bookLength"

    public var chapterId: Int
    public var seriesId: Int
    /// Characters per section (Kavita's "pages", the spine items).
    public var sections: [Int]
    public var total: Int
    /// Kavita's figures when counted: a change means the file changed and needs counting again.
    public var kavitaWordCount: Int?
    public var kavitaPages: Int
    public var countedAt: Date

    public init(chapterId: Int, seriesId: Int, sections: [Int], kavitaWordCount: Int?, kavitaPages: Int, countedAt: Date) {
        self.chapterId = chapterId
        self.seriesId = seriesId
        self.sections = sections
        self.total = sections.reduce(0, +)
        self.kavitaWordCount = kavitaWordCount
        self.kavitaPages = kavitaPages
        self.countedAt = countedAt
    }

    /// Characters before section `index`.
    public func start(of index: Int) -> Int {
        sections.prefix(max(0, min(index, sections.count))).reduce(0, +)
    }

    /// Counted from another version of the file: Kavita's pages or word count changed.
    public func isStale(pages: Int, wordCount: Int?) -> Bool {
        pages != kavitaPages || sections.count != pages
            || (wordCount != nil && kavitaWordCount != nil && wordCount != kavitaWordCount)
    }
}

public struct BookLengths: Sendable {
    let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func length(chapterId: Int) throws -> BookLength? {
        try database.reader.read { try BookLength.fetchOne($0, key: chapterId) }
    }

    public func lengths(seriesId: Int) throws -> [Int: BookLength] {
        try database.reader.read { db in
            Dictionary(try BookLength.filter(Column("seriesId") == seriesId).fetchAll(db).map { ($0.chapterId, $0) },
                       uniquingKeysWith: { first, _ in first })
        }
    }

    public func all() throws -> [Int: BookLength] {
        try database.reader.read { db in
            Dictionary(try BookLength.fetchAll(db).map { ($0.chapterId, $0) }, uniquingKeysWith: { first, _ in first })
        }
    }

    /// Saves a count; one counted from the book keeps Kavita's word count from an earlier one.
    public func save(_ length: BookLength) throws {
        try database.writer.write { db in
            var length = length
            if length.kavitaWordCount == nil, let old = try BookLength.fetchOne(db, key: length.chapterId), old.sections == length.sections {
                length.kavitaWordCount = old.kavitaWordCount
            }
            try length.save(db)
        }
    }

    public func observeCount() -> AsyncThrowingStream<Int, any Error> {
        database.values { try BookLength.fetchCount($0) }
    }
}
