import CryptoKit
import Foundation
import GRDB

/// One kind of record kept the same on every device with "Sync with iCloud" (daily goals, reader
/// settings…). It lists what this device has, each record as JSON under a stable id, and applies
/// a record another device changed (nil: it was deleted). Both run inside a database write.
public protocol SyncedCollection: Sendable {
    /// The folder's name for it ("dailyGoals").
    var name: String { get }
    func records(_ db: Database) throws -> [String: Data]
    func apply(id: String, value: Data?, _ db: Database) throws
}

/// One device's records of one collection, as kept in the sync folder (iCloud): like Stats, a
/// device only writes its own file and reads the others', so two devices never edit one file.
public struct RecordSyncFile: Codable, Equatable, Sendable {
    public struct Record: Codable, Equatable, Sendable {
        public var id: String
        /// The record as JSON text; nil for a deletion.
        public var value: String?
        /// Milliseconds since 1970: the newest edit wins.
        public var editedAt: Int64
        public var deleted: Bool
    }

    public var version = 1
    public var app: String
    public var device: String
    public var records: [Record]

    static func name(app: String, device: String) -> String { "\(app)-\(device).json" }
}

/// Keeps synced collections the same on every device: what changed here since the last sync
/// is stamped and written to this device's file; the other devices' newer records are applied.
/// The newest edit wins per record (ties: the larger device id); a deletion is kept as a
/// tombstone for `tombstoneLife`, so it can't come back from a device that hadn't seen it.
public struct RecordSync: Sendable {
    public static let tombstoneLife: TimeInterval = 90 * 24 * 3600

    public let database: AppDatabase
    public let app: String
    public let collections: [any SyncedCollection]
    let now: @Sendable () -> Date

    public init(database: AppDatabase, app: String, collections: [any SyncedCollection], now: @escaping @Sendable () -> Date = Date.init) {
        self.database = database
        self.app = app
        self.collections = collections
        self.now = now
    }

    /// Syncs every collection, each in `root/<collection>`. True when another device's change
    /// was applied here.
    @discardableResult
    public func sync(root: URL, device: String) throws -> Bool {
        var changed = false
        for collection in collections {
            let folder = StatsSyncFolder(url: root.appending(path: collection.name))
            if try sync(collection, folder: folder, device: device) { changed = true }
        }
        return changed
    }

    func sync(_ collection: any SyncedCollection, folder: StatsSyncFolder, device: String) throws -> Bool {
        try noteLocalEdits(collection, device: device)
        let entries = try folder.entries()
        let applied = try applyOthers(collection, folder: folder, entries: entries, device: device)
        try export(collection, folder: folder, entries: entries, device: device)
        return applied
    }

    /// Compares what the collection holds with what was last synced: a new or changed record is
    /// this device's edit, stamped now (never before an edit already seen, whatever the clock
    /// says); a missing one is deleted.
    func noteLocalEdits(_ collection: any SyncedCollection, device: String) throws {
        try database.writer.write { db in
            let current = try collection.records(db)
            let known = try SyncRecord.filter(Column("collection") == collection.name).fetchAll(db)
            var stamp = try Self.stamp(db, now: now())
            func next() -> Int64 { defer { stamp += 1 }; return stamp }
            var seen = Set<String>()
            for record in known {
                seen.insert(record.id)
                if let value = current[record.id] {
                    guard record.deleted || record.value != value else { continue }
                    try SyncRecord(collection: collection.name, id: record.id, value: value, editedAt: next(), deleted: false, device: device).save(db)
                } else if !record.deleted {
                    try SyncRecord(collection: collection.name, id: record.id, value: nil, editedAt: next(), deleted: true, device: device).save(db)
                }
            }
            for (id, value) in current where !seen.contains(id) {
                try SyncRecord(collection: collection.name, id: id, value: value, editedAt: next(), deleted: false, device: device).save(db)
            }
            // Old tombstones go (from here, and so from this device's file).
            let cutoff = Int64((now().timeIntervalSince1970 - Self.tombstoneLife) * 1000)
            try SyncRecord.filter(Column("collection") == collection.name && Column("deleted") == true && Column("editedAt") < cutoff).deleteAll(db)
        }
    }

    /// The edit time for a new edit: now, or just after the newest edit seen if that's later
    /// (another device's clock ahead of this one's).
    static func stamp(_ db: Database, now: Date) throws -> Int64 {
        let newest = try Int64.fetchOne(db, sql: "SELECT MAX(editedAt) FROM syncRecord") ?? 0
        return max(Int64(now.timeIntervalSince1970 * 1000), newest + 1)
    }

    /// Applies the other devices' records that are newer than what's here.
    func applyOthers(_ collection: any SyncedCollection, folder: StatsSyncFolder, entries: [StatsSyncFolder.Entry], device: String) throws -> Bool {
        let own = RecordSyncFile.name(app: app, device: device)
        var files: [RecordSyncFile] = []
        for entry in entries where entry.isCurrent && entry.name != own && entry.name.hasPrefix("\(app)-") {
            guard let file = try? JSONDecoder().decode(RecordSyncFile.self, from: folder.read(entry.name)),
                  file.app == app, file.device != device, entry.name == RecordSyncFile.name(app: file.app, device: file.device) else { continue }
            files.append(file)
        }
        guard !files.isEmpty else { return false }
        return try database.writer.write { db in
            var applied = false
            let cutoff = Int64((now().timeIntervalSince1970 - Self.tombstoneLife) * 1000)
            for file in files {
                for record in file.records {
                    if record.deleted, record.editedAt < cutoff { continue }
                    let incoming = SyncRecord(collection: collection.name, id: record.id, value: record.value.map { Data($0.utf8) },
                                              editedAt: record.editedAt, deleted: record.deleted, device: file.device)
                    let here = try SyncRecord.fetchOne(db, key: ["collection": collection.name, "id": record.id])
                    guard here.map({ Self.isNewer(incoming, than: $0) }) ?? true else { continue }
                    try collection.apply(id: record.id, value: record.deleted ? nil : incoming.value, db)
                    // Kept as the collection now writes it, so the next look for local edits finds none.
                    var kept = incoming
                    if !record.deleted { kept.value = try collection.records(db)[record.id] ?? incoming.value }
                    try kept.save(db)
                    applied = true
                }
            }
            return applied
        }
    }

    static func isNewer(_ a: SyncRecord, than b: SyncRecord) -> Bool {
        a.editedAt != b.editedAt ? a.editedAt > b.editedAt : a.device > b.device
    }

    /// Writes this device's file: the records whose newest edit was made here (another
    /// device's newer edit is in its own file).
    func export(_ collection: any SyncedCollection, folder: StatsSyncFolder, entries: [StatsSyncFolder.Entry], device: String) throws {
        let name = RecordSyncFile.name(app: app, device: device)
        let records = try database.reader.read { db in
            try SyncRecord.filter(Column("collection") == collection.name && Column("device") == device).order(Column("id")).fetchAll(db)
        }
        let file = RecordSyncFile(app: app, device: device, records: records.map {
            .init(id: $0.id, value: $0.value.map { String(decoding: $0, as: UTF8.self) }, editedAt: $0.editedAt, deleted: $0.deleted)
        })
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(file)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let key = "sync/\(collection.name)/\(name)"
        let saved = try database.reader.read { try String.fetchOne($0, sql: "SELECT token FROM statsSyncFile WHERE name = ?", arguments: [key]) }
        if saved == hash, entries.contains(where: { $0.name == name }) { return }
        try folder.write(data, to: name)
        try database.writer.write { db in
            try db.execute(sql: "INSERT INTO statsSyncFile (name, token) VALUES (?, ?) ON CONFLICT(name) DO UPDATE SET token = excluded.token",
                           arguments: [key, hash])
        }
    }
}

/// A synced record as last merged here: its value, its newest edit and the device that made it.
struct SyncRecord: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "syncRecord"
    var collection: String
    var id: String
    var value: Data?
    var editedAt: Int64
    var deleted: Bool
    var device: String
}
