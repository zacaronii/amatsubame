import Core
import Foundation
import GRDB

struct OCRPageRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "ocrPage"
    var chapterId: Int
    var page: Int
    var modelVersion: String
    var result: Data
    var createdAt: Date
}

/// OCR results by chapter and page, so each page is processed once per model version.
public struct OCRCache: Sendable {
    public let database: AppDatabase
    public let modelVersion: String

    public init(database: AppDatabase, modelVersion: String = OCRModelStore.modelVersion) {
        self.database = database
        self.modelVersion = modelVersion
    }

    public func page(chapterId: Int, page: Int) -> OCRPage? {
        let record = try? database.reader.read { db in
            try OCRPageRecord.fetchOne(db, key: ["chapterId": chapterId, "page": page, "modelVersion": modelVersion])
        }
        return record.flatMap { try? JSONDecoder().decode(OCRPage.self, from: $0.result) }
    }

    public func store(_ result: OCRPage, chapterId: Int, page: Int) throws {
        let record = OCRPageRecord(chapterId: chapterId, page: page, modelVersion: modelVersion,
                                   result: try JSONEncoder().encode(result), createdAt: Date())
        try database.writer.write { try record.save($0) }
    }

    /// Results from older model versions are useless once the models change.
    public func removeOtherVersions() throws {
        _ = try database.writer.write { try OCRPageRecord.filter(Column("modelVersion") != modelVersion).deleteAll($0) }
    }

    public func clear() throws {
        _ = try database.writer.write { try OCRPageRecord.deleteAll($0) }
    }

    public func count() throws -> Int {
        try database.reader.read { try OCRPageRecord.fetchCount($0) }
    }
}
