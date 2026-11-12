import Core
import Foundation
import GRDB

/// Library browsing backed by the SQLite cache: screens show cached rows
/// immediately, then refresh from Kavita when it's reachable.
public struct KavitaLibraryRepository: Sendable {
    public let database: AppDatabase
    public let now: @Sendable () -> Date

    public init(database: AppDatabase, now: @escaping @Sendable () -> Date = Date.init) {
        self.database = database
        self.now = now
    }

    // MARK: Cached reads

    public func cachedLibraries() throws -> [KavitaLibrary] {
        try database.reader.read { db in
            try KavitaLibraryRecord.order(Column("name")).fetchAll(db).map {
                KavitaLibrary(id: $0.id, name: $0.name, type: $0.type ?? 0)
            }
        }
    }

    public func cachedSeries(libraryId: Int) throws -> [KavitaSeries] {
        try database.reader.read { db in
            try KavitaSeriesRecord
                .filter(Column("libraryId") == libraryId)
                .order(sql: "COALESCE(sortName, name) COLLATE NOCASE")
                .fetchAll(db)
                .compactMap(Self.decodeSeries)
        }
    }

    public func cachedSeries(id: Int) throws -> KavitaSeries? {
        try database.reader.read { db in
            try KavitaSeriesRecord.fetchOne(db, key: id).flatMap(Self.decodeSeries)
        }
    }

    public func cachedVolumes(seriesId: Int) throws -> [KavitaVolume] {
        try database.reader.read { db in
            try KavitaVolumeRecord.filter(Column("seriesId") == seriesId).fetchAll(db).compactMap { record in
                record.raw.flatMap { try? KavitaJSON.decoder.decode(KavitaVolume.self, from: $0) }
            }
        }
    }

    /// The series a cached chapter belongs to.
    public func cachedSeriesId(chapterId: Int) throws -> Int? {
        try database.reader.read { db in try KavitaChapterRecord.fetchOne(db, key: chapterId)?.seriesId }
    }

    private static func decodeSeries(_ record: KavitaSeriesRecord) -> KavitaSeries? {
        if let raw = record.raw, let series = try? KavitaJSON.decoder.decode(KavitaSeries.self, from: raw) {
            return series
        }
        return KavitaSeries(id: record.id, name: record.name, sortName: record.sortName, libraryId: record.libraryId,
                            format: record.format ?? 0, pages: record.pages ?? 0, pagesRead: record.pagesRead ?? 0,
                            latestReadDate: record.lastReadAt)
    }

    // MARK: Refresh

    @discardableResult
    public func refreshLibraries(using client: KavitaClient) async throws -> [KavitaLibrary] {
        let fetched = try await client.libraries()
        let now = now()
        try await database.writer.write { db in
            let ids = fetched.map(\.0.id)
            _ = try KavitaLibraryRecord.filter(!ids.contains(Column("id"))).deleteAll(db)
            for (library, raw) in fetched {
                try KavitaLibraryRecord(id: library.id, name: library.name, type: library.type, raw: raw, fetchedAt: now).save(db)
            }
        }
        return try cachedLibraries()
    }

    /// Fetches every page of a library's series and replaces the cached list.
    @discardableResult
    public func refreshSeries(libraryId: Int, using client: KavitaClient) async throws -> [KavitaSeries] {
        var all: [(KavitaSeries, raw: Data)] = []
        var page = 1
        while true {
            let result = try await client.series(libraryId: libraryId, page: page)
            all += result.items
            guard result.hasMore, !result.items.isEmpty else { break }
            page += 1
        }
        let now = now()
        try await database.writer.write { [all] db in
            let ids = all.map(\.0.id)
            _ = try KavitaSeriesRecord
                .filter(Column("libraryId") == libraryId && !ids.contains(Column("id")))
                .deleteAll(db)
            for (series, raw) in all {
                try Self.seriesRecord(series, raw: raw, fetchedAt: now).save(db)
            }
        }
        return try cachedSeries(libraryId: libraryId)
    }

    @discardableResult
    public func refreshVolumes(seriesId: Int, using client: KavitaClient) async throws -> [KavitaVolume] {
        let fetched = try await client.volumes(seriesId: seriesId)
        let now = now()
        try await database.writer.write { db in
            // Chapters cascade from their volume.
            _ = try KavitaVolumeRecord.filter(Column("seriesId") == seriesId).deleteAll(db)
            guard try KavitaSeriesRecord.exists(db, key: seriesId) else { return }
            for (volume, raw) in fetched {
                try KavitaVolumeRecord(id: volume.id, seriesId: seriesId, name: volume.name, number: volume.number,
                                       pages: volume.pages, pagesRead: volume.pagesRead, raw: raw, fetchedAt: now).insert(db)
                for chapter in volume.chapters {
                    try KavitaChapterRecord(id: chapter.id, volumeId: volume.id, seriesId: seriesId, title: chapter.title,
                                            number: chapter.number, sortOrder: chapter.sortOrder, pages: chapter.pages,
                                            pagesRead: chapter.pagesRead, isSpecial: chapter.isSpecial, raw: nil,
                                            fetchedAt: now).insert(db)
                }
            }
        }
        return fetched.map(\.0)
    }

    /// Caches series seen outside a library listing (e.g. On Deck) so detail screens work offline.
    public func remember(_ series: [(KavitaSeries, raw: Data)]) throws {
        let now = now()
        try database.writer.write { db in
            for (item, raw) in series where try KavitaLibraryRecord.exists(db, key: item.libraryId) {
                try Self.seriesRecord(item, raw: raw, fetchedAt: now).save(db)
            }
        }
    }

    private static func seriesRecord(_ series: KavitaSeries, raw: Data?, fetchedAt: Date) -> KavitaSeriesRecord {
        KavitaSeriesRecord(id: series.id, libraryId: series.libraryId, name: series.name, sortName: series.sortName,
                           format: series.format, pages: series.pages, pagesRead: series.pagesRead,
                           lastReadAt: series.latestReadDate, raw: raw, fetchedAt: fetchedAt)
    }
}
