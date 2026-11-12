import Foundation
import GRDB

public enum DownloadKind: String, Codable, Sendable, DatabaseValueConvertible {
    /// A Kavita volume or chapter (manga pages or an EPUB), keyed by chapter id.
    case kavitaChapter
    /// A Jellyfin episode or movie (the original file), keyed by item id.
    case jellyfinItem
    /// An Audiobookshelf podcast episode (its audio file), keyed by "<item id>/<episode id>".
    case audiobookshelfEpisode
}

public enum DownloadState: String, Codable, Sendable, DatabaseValueConvertible {
    /// Waiting its turn (or for Wi-Fi).
    case queued
    case downloading
    case paused
    /// On the device.
    case done
    case failed
}

/// One thing the user asked to keep on the device.
public struct DownloadRecord: Codable, Equatable, Identifiable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "download"

    public var id: Int64?
    public var kind: DownloadKind
    public var itemKey: String
    public var seriesKey: String?
    public var seriesTitle: String
    public var title: String
    public var detail: String?
    public var state: DownloadState
    public var bytesDone: Int64
    public var bytesTotal: Int64?
    public var error: String?
    /// Path relative to the app's downloads folder, when the download is one file.
    public var file: String?
    /// App-specific metadata (e.g. what's needed to play an episode offline).
    public var extra: Data?
    public var createdAt: Date
    public var completedAt: Date?

    public init(kind: DownloadKind, itemKey: String, seriesKey: String?, seriesTitle: String, title: String, detail: String? = nil,
                bytesTotal: Int64? = nil, extra: Data? = nil, createdAt: Date) {
        self.kind = kind
        self.itemKey = itemKey
        self.seriesKey = seriesKey
        self.seriesTitle = seriesTitle
        self.title = title
        self.detail = detail
        state = .queued
        bytesDone = 0
        self.bytesTotal = bytesTotal
        self.extra = extra
        self.createdAt = createdAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    /// 0…1 while downloading, when the size is known.
    public var fraction: Double? {
        guard let total = bytesTotal, total > 0 else { return nil }
        return min(Double(bytesDone) / Double(total), 1)
    }

    public var isActive: Bool { state == .queued || state == .downloading }
}

/// Downloads grouped by series, for the Downloads tab.
public struct DownloadGroup: Identifiable, Equatable, Sendable {
    public var seriesKey: String?
    public var seriesTitle: String
    public var downloads: [DownloadRecord]
    public var id: String { seriesKey ?? "title:\(seriesTitle)" }
    public var bytes: Int64 { downloads.reduce(0) { $0 + ($1.state == .done ? ($1.bytesTotal ?? $1.bytesDone) : $1.bytesDone) } }
}

public struct DownloadStore: Sendable {
    public let database: AppDatabase
    public let now: @Sendable () -> Date

    public init(database: AppDatabase, now: @escaping @Sendable () -> Date = Date.init) {
        self.database = database
        self.now = now
    }

    /// Adds a download, or returns the existing one for the same item (a failed or paused
    /// one is queued again).
    @discardableResult
    public func enqueue(_ record: DownloadRecord) throws -> DownloadRecord {
        try database.writer.write { db in
            if var existing = try DownloadRecord.filter(Column("kind") == record.kind && Column("itemKey") == record.itemKey).fetchOne(db) {
                if existing.state == .failed || existing.state == .paused {
                    existing.state = .queued
                    existing.error = nil
                    try existing.update(db)
                }
                return existing
            }
            var record = record
            record.state = .queued
            try record.insert(db)
            return record
        }
    }

    public func download(kind: DownloadKind, itemKey: String) throws -> DownloadRecord? {
        try database.reader.read { db in
            try DownloadRecord.filter(Column("kind") == kind && Column("itemKey") == itemKey).fetchOne(db)
        }
    }

    public func download(id: Int64) throws -> DownloadRecord? {
        try database.reader.read { try DownloadRecord.fetchOne($0, key: id) }
    }

    /// The next download waiting its turn, oldest first.
    public func nextQueued(kind: DownloadKind) throws -> DownloadRecord? {
        try database.reader.read { db in
            try DownloadRecord.filter(Column("kind") == kind && Column("state") == DownloadState.queued)
                .order(Column("createdAt"), Column("id")).fetchOne(db)
        }
    }

    public func all(kind: DownloadKind) throws -> [DownloadRecord] {
        try database.reader.read { db in
            try DownloadRecord.filter(Column("kind") == kind).order(Column("createdAt"), Column("id")).fetchAll(db)
        }
    }

    public func setState(_ id: Int64, _ state: DownloadState, error: String? = nil) throws {
        let now = now()
        try database.writer.write { db in
            guard var record = try DownloadRecord.fetchOne(db, key: id) else { return }
            record.state = state
            record.error = error
            if state == .done { record.completedAt = now }
            try record.update(db)
        }
    }

    public func setProgress(_ id: Int64, done: Int64, total: Int64?) throws {
        try database.writer.write { db in
            try db.execute(sql: "UPDATE download SET bytesDone = ?, bytesTotal = COALESCE(?, bytesTotal), state = ? WHERE id = ? AND state != ?",
                           arguments: [done, total, DownloadState.downloading, id, DownloadState.done])
        }
    }

    /// Marks a download finished, with its file (if one) and final size.
    public func finish(_ id: Int64, file: String?, bytes: Int64, extra: Data? = nil) throws {
        let now = now()
        try database.writer.write { db in
            guard var record = try DownloadRecord.fetchOne(db, key: id) else { return }
            record.state = .done
            record.file = file
            record.bytesDone = bytes
            record.bytesTotal = bytes
            record.error = nil
            record.completedAt = now
            if let extra { record.extra = extra }
            try record.update(db)
        }
    }

    /// Replaces a download's app-specific metadata, leaving its state alone.
    public func setExtra(_ id: Int64, _ extra: Data?) throws {
        try database.writer.write { db in
            try db.execute(sql: "UPDATE download SET extra = ? WHERE id = ?", arguments: [extra, id])
        }
    }

    /// Forgets a download (the app removes its files).
    public func remove(_ id: Int64) throws {
        _ = try database.writer.write { try DownloadRecord.deleteOne($0, key: id) }
    }

    /// Failed downloads go back in the queue (at launch: most failures were the connection).
    public func requeueFailed(kind: DownloadKind) throws {
        try database.writer.write { db in
            try db.execute(sql: "UPDATE download SET state = ?, error = NULL WHERE kind = ? AND state = ?",
                           arguments: [DownloadState.queued, kind, DownloadState.failed])
        }
    }

    /// Downloads that were mid-transfer when the app last quit go back in the queue.
    public func requeueInterrupted() throws {
        try database.writer.write { db in
            try db.execute(sql: "UPDATE download SET state = ? WHERE state = ?", arguments: [DownloadState.queued, DownloadState.downloading])
        }
    }

    /// Grouped by series, series by title and downloads in order added. Steady order: sorting
    /// series by their newest download made them leapfrog as volumes finished.
    public static func grouped(_ records: [DownloadRecord]) -> [DownloadGroup] {
        var groups: [String: DownloadGroup] = [:]
        for record in records {
            let key = record.seriesKey ?? "title:\(record.seriesTitle)"
            groups[key, default: DownloadGroup(seriesKey: record.seriesKey, seriesTitle: record.seriesTitle, downloads: [])]
                .downloads.append(record)
        }
        return groups.values.sorted { a, b in
            let order = a.seriesTitle.localizedStandardCompare(b.seriesTitle)
            return order == .orderedSame ? a.id < b.id : order == .orderedAscending
        }
    }

    public func observe(kind: DownloadKind) -> AsyncThrowingStream<[DownloadRecord], any Error> {
        database.values { db in
            try DownloadRecord.filter(Column("kind") == kind).order(Column("createdAt"), Column("id")).fetchAll(db)
        }
    }

    /// Bytes on the device for finished downloads.
    public func totalBytes(kind: DownloadKind) throws -> Int64 {
        try database.reader.read { db in
            try Int64.fetchOne(db, sql: "SELECT COALESCE(SUM(bytesTotal), 0) FROM download WHERE kind = ? AND state = ?",
                               arguments: [kind, DownloadState.done]) ?? 0
        }
    }
}

/// How downloads behave (Settings).
public struct DownloadSettings: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "downloadSettings"
    var id = 1
    /// Off: downloads wait for Wi-Fi.
    public var allowsCellular = false
    /// Reader: OCR downloaded manga pages so lookups are instant offline.
    public var readsDownloadedPages = true

    public init(allowsCellular: Bool = false, readsDownloadedPages: Bool = true) {
        self.allowsCellular = allowsCellular
        self.readsDownloadedPages = readsDownloadedPages
    }

    public static func load(_ database: AppDatabase) -> DownloadSettings {
        (try? database.reader.read { try DownloadSettings.fetchOne($0, key: 1) }) ?? DownloadSettings()
    }

    public func save(_ database: AppDatabase) throws {
        try database.writer.write { try self.save($0) }
    }

    public static func observe(_ database: AppDatabase) -> AsyncThrowingStream<DownloadSettings, any Error> {
        database.values { try DownloadSettings.fetchOne($0, key: 1) ?? DownloadSettings() }
    }
}

/// Reader automatic downloads for one Kavita library (off unless the user turns it on).
public struct AutoDownloadSetting: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "autoDownloadSetting"

    public var libraryId: Int
    /// Volumes kept downloaded after the one being read; 0 is off.
    public var ahead: Int
    /// Fully read volumes in this library are removed from the device.
    public var removesFinished: Bool

    public init(libraryId: Int, ahead: Int = 0, removesFinished: Bool = false) {
        self.libraryId = libraryId
        self.ahead = ahead
        self.removesFinished = removesFinished
    }

    public var isOff: Bool { ahead == 0 && !removesFinished }
}

public struct AutoDownloadSettingsStore: Sendable {
    public let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    /// Settings by library id; libraries without a row are off.
    public func all() throws -> [Int: AutoDownloadSetting] {
        try database.reader.read { db in
            Dictionary(try AutoDownloadSetting.fetchAll(db).map { ($0.libraryId, $0) }, uniquingKeysWith: { $1 })
        }
    }

    public func setting(libraryId: Int) throws -> AutoDownloadSetting {
        try database.reader.read { try AutoDownloadSetting.fetchOne($0, key: libraryId) } ?? AutoDownloadSetting(libraryId: libraryId)
    }

    public func save(_ setting: AutoDownloadSetting) throws {
        try database.writer.write { db in
            if setting.isOff {
                _ = try AutoDownloadSetting.deleteOne(db, key: setting.libraryId)
            } else {
                try setting.save(db)
            }
        }
    }

    public func observe() -> AsyncThrowingStream<[Int: AutoDownloadSetting], any Error> {
        database.values { db in
            Dictionary(try AutoDownloadSetting.fetchAll(db).map { ($0.libraryId, $0) }, uniquingKeysWith: { $1 })
        }
    }
}
