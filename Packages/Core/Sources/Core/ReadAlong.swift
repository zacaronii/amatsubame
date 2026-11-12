import Foundation
import GRDB

/// Yomu's read-along: an EPUB volume (Kavita chapter) paired with an Audiobookshelf audiobook,
/// and once prepared, its alignment (the cues, encoded by the Readers package).
public struct ReadAlongPair: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "readAlongPair"

    public var chapterId: Int
    public var itemId: String
    public var bookTitle: String
    public var createdAt: Date
    /// Set once prepared: when, for which transcript, and how much of the book matched.
    public var alignedAt: Date?
    public var transcriptFingerprint: String?
    public var alignmentVersion: Int?
    public var cues: Data?
    public var matchedSentences: Int?
    public var totalSentences: Int?
    /// Read along when the volume opens; off is plain reading (the reader's headphones button).
    public var readsAlong = true

    public init(chapterId: Int, itemId: String, bookTitle: String, createdAt: Date) {
        self.chapterId = chapterId
        self.itemId = itemId
        self.bookTitle = bookTitle
        self.createdAt = createdAt
    }
}

public struct ReadAlongStore: Sendable {
    let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func pair(chapterId: Int) throws -> ReadAlongPair? {
        try database.reader.read { try ReadAlongPair.fetchOne($0, key: chapterId) }
    }

    /// The volumes paired with an Audiobookshelf book, newest pairing first.
    public func pairs(itemId: String) throws -> [ReadAlongPair] {
        try database.reader.read { db in
            try ReadAlongPair.filter(Column("itemId") == itemId).order(Column("createdAt").desc).fetchAll(db)
        }
    }

    public func observe(chapterId: Int) -> AsyncThrowingStream<ReadAlongPair?, any Error> {
        database.values { try ReadAlongPair.fetchOne($0, key: chapterId) }
    }

    /// Pairs a volume with a book (replacing an earlier pairing and its alignment).
    public func pair(_ pair: ReadAlongPair) throws {
        try database.writer.write { try pair.save($0) }
    }

    public func saveAlignment(chapterId: Int, cues: Data, version: Int, fingerprint: String?, matched: Int, total: Int, at date: Date) throws {
        try database.writer.write { db in
            try db.execute(sql: """
                UPDATE readAlongPair SET cues = ?, alignmentVersion = ?, transcriptFingerprint = ?, matchedSentences = ?,
                totalSentences = ?, alignedAt = ? WHERE chapterId = ?
                """, arguments: [cues, version, fingerprint, matched, total, date, chapterId])
        }
    }

    public func setReadsAlong(chapterId: Int, _ on: Bool) throws {
        try database.writer.write { db in
            try db.execute(sql: "UPDATE readAlongPair SET readsAlong = ? WHERE chapterId = ?", arguments: [on, chapterId])
        }
    }

    public func unpair(chapterId: Int) throws {
        _ = try database.writer.write { try ReadAlongPair.deleteOne($0, key: chapterId) }
    }
}
