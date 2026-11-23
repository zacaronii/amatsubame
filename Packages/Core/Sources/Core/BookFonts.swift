import Foundation
import GRDB

/// A font the reader added for reading books. Its file is in Yomu's own container (each
/// device adds its own; nothing is synced). `id` is a UUID string, the file's name without
/// its extension, and the only thing the book pages ask for.
public struct BookFont: Codable, Equatable, Hashable, Sendable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "bookFont"

    public var id: String
    public var name: String
    public var fileName: String
    public var addedAt: Date

    public init(id: String, name: String, fileName: String, addedAt: Date) {
        self.id = id
        self.name = name
        self.fileName = fileName
        self.addedAt = addedAt
    }

    /// At most this many fonts, each at most `maxBytes` (CJK fonts are large).
    public static let maxCount = 20
    public static let maxBytes = 50 * 1024 * 1024

    /// An id as the book pages may ask for it: a UUID's letters, digits and dashes, nothing else
    /// (no path parts).
    public static func isValidID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "-" }
    }
}

public struct BookFontStore: Sendable {
    let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func fonts() throws -> [BookFont] {
        try database.reader.read { try BookFont.order(Column("addedAt")).fetchAll($0) }
    }

    public func font(id: String) throws -> BookFont? {
        guard BookFont.isValidID(id) else { return nil }
        return try database.reader.read { try BookFont.fetchOne($0, key: id) }
    }

    public func add(_ font: BookFont) throws {
        try database.writer.write { try font.insert($0) }
    }

    public func rename(_ id: String, to name: String) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        try database.writer.write { try $0.execute(sql: "UPDATE bookFont SET name = ? WHERE id = ?", arguments: [name, id]) }
    }

    public func remove(_ id: String) throws {
        _ = try database.writer.write { try BookFont.deleteOne($0, key: id) }
    }

    public func observe() -> AsyncThrowingStream<[BookFont], any Error> {
        database.values { try BookFont.order(Column("addedAt")).fetchAll($0) }
    }
}
