import Foundation
import GRDB

/// A Kavita collection as this device knows it (per Kavita account): Kavita's list, plus a New
/// Collection or a deletion not sent yet.
public struct CollectionRow: Codable, Equatable, Hashable, Sendable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "kavitaCollection"

    public enum State: String, Codable, Sendable, DatabaseValueConvertible {
        case synced
        /// Made here, not on Kavita yet (Kavita's id comes with the create).
        case pendingCreate
        /// Deleted here; the row goes once Kavita has deleted it too.
        case pendingDelete
    }

    public var id: Int64?
    /// `ReaderMarkStore.accountKey` of the Kavita account.
    public var account: String
    /// Kavita's id; nil until the create is sent.
    public var serverId: Int?
    public var title: String
    /// Made by this account (others' are promoted ones, read-only).
    public var isOwn: Bool
    public var owner: String?
    public var promoted: Bool
    /// Kavita's `source`: 0 made on Kavita; others are synced from outside (AniList, MAL…).
    public var source: Int
    /// Kavita's count of its series (all of them, shown or not).
    public var itemCount: Int
    /// Its place in Kavita's list.
    public var position: Int
    public var state: State
    /// Kavita has had this collection with a series in it (or listed it): an empty one Kavita
    /// cleans up can then only mean it was deleted on purpose.
    public var confirmed: Bool
    /// How often the create was sent again because Kavita had cleaned up the empty collection.
    public var createAttempts: Int
    /// When its whole series list was last read (opening it): until then only `itemCount` says
    /// how many it has.
    public var seriesReadAt: Date?
    public var revision: Int
    public var updatedAt: Date

    public init(id: Int64? = nil, account: String, serverId: Int? = nil, title: String, isOwn: Bool = true, owner: String? = nil,
                promoted: Bool = false, source: Int = 0, itemCount: Int = 0, position: Int = 0, state: State,
                confirmed: Bool = false, createAttempts: Int = 0, seriesReadAt: Date? = nil, revision: Int = 0, updatedAt: Date) {
        self.id = id
        self.account = account
        self.serverId = serverId
        self.title = title
        self.isOwn = isOwn
        self.owner = owner
        self.promoted = promoted
        self.source = source
        self.itemCount = itemCount
        self.position = position
        self.state = state
        self.confirmed = confirmed
        self.createAttempts = createAttempts
        self.seriesReadAt = seriesReadAt
        self.revision = revision
        self.updatedAt = updatedAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    /// Series can be added and removed, and it can be deleted, from Yomu: the account's own,
    /// made on Kavita (not synced from AniList, MAL…).
    public var isEditable: Bool { isOwn && source == 0 }

    /// Kavita's way of comparing titles (`ToNormalized`): only letters, ASCII digits and
    /// `+ ! ＊ ！ ＋` count, lowercased.
    public static func normalized(_ title: String) -> String {
        String(title.unicodeScalars.filter { scalar in
            scalar.properties.generalCategory.isLetter || ("0"..."9").contains(scalar) || "+!＊！＋".unicodeScalars.contains(scalar)
        }.map(Character.init)).lowercased()
    }
}

private extension Unicode.GeneralCategory {
    var isLetter: Bool {
        switch self {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: true
        default: false
        }
    }
}

/// A series in a collection, as this device knows it.
public struct CollectionSeriesRow: Codable, Equatable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "kavitaCollectionSeries"

    public enum State: String, Codable, Sendable, DatabaseValueConvertible {
        case synced
        case pendingAdd
        case pendingRemove
        /// Taken by Kavita: kept until a list fetched after that no longer differs.
        case removed
    }

    /// `CollectionRow.id` (the local one).
    public var collectionId: Int64
    public var seriesId: Int
    public var state: State
    /// Whether Kavita has it in the collection, as last known (listed, or an add or remove it took).
    public var inKavita: Bool
    public var revision: Int
    public var updatedAt: Date

    public init(collectionId: Int64, seriesId: Int, state: State, inKavita: Bool, revision: Int = 0, updatedAt: Date) {
        self.collectionId = collectionId
        self.seriesId = seriesId
        self.state = state
        self.inKavita = inKavita
        self.revision = revision
        self.updatedAt = updatedAt
    }

    public var isIn: Bool { state == .synced || state == .pendingAdd }
}

/// The outbox job for one collection: its create or delete (`seriesId` nil), or one series'
/// add or remove.
public struct CollectionJob: Codable, Equatable, Sendable {
    public var account: String
    public var collectionId: Int64
    public var seriesId: Int?

    public init(account: String, collectionId: Int64, seriesId: Int? = nil) {
        self.account = account
        self.collectionId = collectionId
        self.seriesId = seriesId
    }

    public var coalesceKey: String {
        "collection:\(account):\(collectionId)" + (seriesId.map { ":\($0)" } ?? "")
    }
}

public enum CollectionError: Error, Equatable, LocalizedError {
    /// Another account's (promoted) collection, or one synced from outside Kavita.
    case readOnly(String)
    case emptyTitle
    /// An own collection already has the title (as Kavita compares them).
    case titleTaken(String)

    public var errorDescription: String? {
        switch self {
        case .readOnly(let title): "\u{201C}\(title)\u{201D} can't be changed from Yomu."
        case .emptyTitle: "A collection needs a title."
        case .titleTaken(let title): "You already have a collection called \u{201C}\(title)\u{201D}."
        }
    }
}

public struct CollectionStore: Sendable {
    public let database: AppDatabase
    let now: @Sendable () -> Date

    public init(database: AppDatabase, now: @escaping @Sendable () -> Date = Date.init) {
        self.database = database
        self.now = now
    }

    // MARK: Reading

    /// The account's collections in Kavita's order (new ones first), without deleted ones.
    public func observe(account: String) -> AsyncThrowingStream<[CollectionRow], any Error> {
        database.values { try Self.collections($0, account: account) }
    }

    public func collections(account: String) throws -> [CollectionRow] {
        try database.reader.read { try Self.collections($0, account: account) }
    }

    static func collections(_ db: Database, account: String) throws -> [CollectionRow] {
        let rows = try CollectionRow.filter(Column("account") == account && Column("state") != CollectionRow.State.pendingDelete).fetchAll(db)
        return rows.filter { $0.state == .pendingCreate }.sorted { $0.updatedAt > $1.updatedAt }
            + rows.filter { $0.state == .synced }.sorted { $0.position < $1.position }
    }

    public func collection(_ id: Int64) throws -> CollectionRow? {
        try database.reader.read { try CollectionRow.fetchOne($0, key: id) }
    }

    /// A collection's series on this device (Kavita's, with unsent adds and without unsent removes).
    public func observeSeries(collectionId: Int64) -> AsyncThrowingStream<[Int], any Error> {
        database.values { db in
            try CollectionSeriesRow.filter(Column("collectionId") == collectionId).fetchAll(db).filter(\.isIn).map(\.seriesId)
        }
    }

    /// The collections a series is in on this device (local ids).
    public func observeCollections(ofSeries seriesId: Int, account: String) -> AsyncThrowingStream<Set<Int64>, any Error> {
        database.values { db in
            let ids = Set(try Self.collections(db, account: account).compactMap(\.id))
            return Set(try CollectionSeriesRow.filter(Column("seriesId") == seriesId).fetchAll(db)
                .filter { $0.isIn && ids.contains($0.collectionId) }.map(\.collectionId))
        }
    }

    public func seriesRow(collectionId: Int64, seriesId: Int) throws -> CollectionSeriesRow? {
        try database.reader.read { try CollectionSeriesRow.fetchOne($0, key: ["collectionId": collectionId, "seriesId": seriesId]) }
    }

    /// How many series the collection will have once this device's unsent changes are sent, or
    /// nil when that can't be told (the series read earlier don't add up to Kavita's count any
    /// more): what "the last series" is judged on, the whole collection, not the series shown.
    /// `itemCount` is Kavita's count, kept up to date with the changes Kavita has taken from here.
    public func seriesCount(collectionId: Int64) throws -> Int? {
        try database.reader.read { db in
            guard let collection = try CollectionRow.fetchOne(db, key: collectionId) else { return 0 }
            let rows = try CollectionSeriesRow.filter(Column("collectionId") == collectionId).fetchAll(db)
            if collection.seriesReadAt != nil, rows.filter(\.inKavita).count != collection.itemCount { return nil }
            let unsent = rows.filter { $0.state == .pendingAdd || $0.state == .pendingRemove }
                .reduce(0) { $0 + ($1.isIn ? 1 : 0) - ($1.inKavita ? 1 : 0) }
            return max(0, collection.itemCount + unsent)
        }
    }

    /// What taking a series out of a collection does, as far as this device can tell.
    public enum TakeOut: Equatable, Sendable {
        /// Others stay in it.
        case notLast
        /// It's the last: Kavita deletes the collection (Yomu deletes it, and says so first).
        case last
        /// The series read earlier don't add up to Kavita's count: it may be the last. Yomu asks,
        /// but only takes the series out (the handler's look afterwards drops the collection if
        /// Kavita deleted it).
        case unknown
    }

    public func takeOut(_ seriesId: Int, collectionId: Int64) throws -> TakeOut {
        guard let count = try seriesCount(collectionId: collectionId) else { return .unknown }
        let isIn = try seriesRow(collectionId: collectionId, seriesId: seriesId)?.isIn ?? false
        return count - (isIn ? 1 : 0) <= 0 ? .last : .notLast
    }

    // MARK: Changes made here (each in one write with its job)

    /// Makes a collection with the series in it (Kavita can't keep an empty one: it's made
    /// empty, then the series is added, and its cleanup removes empty collections).
    @discardableResult
    public func create(title raw: String, with seriesId: Int, account: String, outbox: OutboxStore) throws -> CollectionRow {
        let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !CollectionRow.normalized(title).isEmpty else { throw CollectionError.emptyTitle }
        return try database.writer.write { db in
            let taken = try Self.collections(db, account: account).filter(\.isOwn)
                .contains { CollectionRow.normalized($0.title) == CollectionRow.normalized(title) }
            guard !taken else { throw CollectionError.titleTaken(title) }
            var row = CollectionRow(account: account, title: title, state: .pendingCreate, updatedAt: now())
            try row.insert(db)
            let id = row.id!
            try queue(CollectionJob(account: account, collectionId: id), outbox: outbox, in: db)
            try CollectionSeriesRow(collectionId: id, seriesId: seriesId, state: .pendingAdd, inKavita: false, revision: 1, updatedAt: now()).insert(db)
            try queue(CollectionJob(account: account, collectionId: id, seriesId: seriesId), outbox: outbox, in: db)
            return row
        }
    }

    /// Adds the series to the collection or takes it out.
    public func set(_ inCollection: Bool, seriesId: Int, collectionId: Int64, outbox: OutboxStore) throws {
        try database.writer.write { db in
            guard let collection = try CollectionRow.fetchOne(db, key: collectionId), collection.state != .pendingDelete else { return }
            guard collection.isEditable else { throw CollectionError.readOnly(collection.title) }
            var row = try CollectionSeriesRow.fetchOne(db, key: ["collectionId": collectionId, "seriesId": seriesId])
                ?? CollectionSeriesRow(collectionId: collectionId, seriesId: seriesId, state: .removed, inKavita: false, updatedAt: now())
            guard row.isIn != inCollection else { return }
            row.state = inCollection ? .pendingAdd : .pendingRemove
            row.revision += 1
            row.updatedAt = now()
            try row.save(db)
            try queue(CollectionJob(account: collection.account, collectionId: collectionId, seriesId: seriesId), outbox: outbox, in: db)
        }
    }

    /// Deletes the collection: gone here at once, and its waiting adds and removes with it.
    public func delete(_ collectionId: Int64, outbox: OutboxStore) throws {
        try database.writer.write { db in
            guard var collection = try CollectionRow.fetchOne(db, key: collectionId) else { return }
            guard collection.isEditable else { throw CollectionError.readOnly(collection.title) }
            try Self.cancelSeriesJobs(db, collection)
            try CollectionSeriesRow.filter(Column("collectionId") == collectionId).deleteAll(db)
            if collection.serverId == nil {
                // Never made on Kavita: nothing to delete there (a create on its way finds no row).
                try OutboxStore.cancel(db, coalesceKeys: [CollectionJob(account: collection.account, collectionId: collectionId).coalesceKey])
                try collection.delete(db)
                return
            }
            collection.state = .pendingDelete
            collection.revision += 1
            collection.updatedAt = now()
            try collection.update(db)
            try queue(CollectionJob(account: collection.account, collectionId: collectionId), outbox: outbox, in: db)
        }
    }

    private static func cancelSeriesJobs(_ db: Database, _ collection: CollectionRow) throws {
        guard let id = collection.id else { return }
        let keys = try CollectionSeriesRow.filter(Column("collectionId") == id).fetchAll(db)
            .map { CollectionJob(account: collection.account, collectionId: id, seriesId: $0.seriesId).coalesceKey }
        try OutboxStore.cancel(db, coalesceKeys: keys)
    }

    func queue(_ job: CollectionJob, outbox: OutboxStore, in db: Database) throws {
        try outbox.enqueue(job, kind: .kavitaCollection, coalesceKey: job.coalesceKey, in: db)
    }

    // MARK: For the outbox handler

    /// Whether a job for this key is still listed (waiting, sending, or failed and listed).
    public func isQueued(_ job: CollectionJob) throws -> Bool {
        try database.reader.read { try OutboxStore.queuedKeys($0, kind: .kavitaCollection).contains(job.coalesceKey) }
    }

    /// The create reached Kavita: its id. False when the collection was deleted here meanwhile
    /// (what was made is then deleted on Kavita too, if this create made it).
    @discardableResult
    public func didCreate(_ collectionId: Int64, serverId: Int) throws -> Bool {
        try database.writer.write { db in
            guard var row = try CollectionRow.fetchOne(db, key: collectionId) else { return false }
            guard row.state == .pendingCreate else { return true }
            row.serverId = serverId
            row.state = .synced
            row.updatedAt = now()
            try row.update(db)
            return true
        }
    }

    /// Kavita deleted it.
    public func didDelete(_ collectionId: Int64) throws {
        _ = try database.writer.write { db in
            try CollectionSeriesRow.filter(Column("collectionId") == collectionId).deleteAll(db)
            return try CollectionRow.deleteOne(db, key: collectionId)
        }
    }

    /// Kavita took a series' add or remove (`sent` as it was when the job read it).
    public func didSend(_ sent: CollectionSeriesRow) throws {
        try database.writer.write { db in
            guard var row = try CollectionSeriesRow.fetchOne(db, key: ["collectionId": sent.collectionId, "seriesId": sent.seriesId]),
                  row.revision == sent.revision, row.state == .pendingAdd || row.state == .pendingRemove else { return }
            let added = row.state == .pendingAdd
            let wasIn = row.inKavita
            row.state = added ? .synced : .removed
            row.inKavita = added
            row.updatedAt = now()
            try row.update(db)
            if var collection = try CollectionRow.fetchOne(db, key: sent.collectionId) {
                if added { collection.confirmed = true }
                collection.itemCount = max(0, collection.itemCount + (added ? 1 : 0) - (wasIn ? 1 : 0))
                try collection.update(db)
            }
        }
    }

    /// A series row whose job can't do anything any more (its collection gone): it goes.
    public func dropSeries(_ row: CollectionSeriesRow) throws {
        _ = try database.writer.write { try CollectionSeriesRow.deleteOne($0, key: ["collectionId": row.collectionId, "seriesId": row.seriesId]) }
    }

    /// Kavita cleaned up a collection made here before its first series got in (it was empty):
    /// it's made again, in the same write as its create job, at most twice. Returns false once
    /// that's been tried enough.
    public func recreate(_ collectionId: Int64, outbox: OutboxStore) throws -> Bool {
        try database.writer.write { db in
            guard var row = try CollectionRow.fetchOne(db, key: collectionId), !row.confirmed, row.createAttempts < 2 else { return false }
            row.serverId = nil
            row.state = .pendingCreate
            row.createAttempts += 1
            row.updatedAt = now()
            try row.update(db)
            try queue(CollectionJob(account: row.account, collectionId: collectionId), outbox: outbox, in: db)
            return true
        }
    }

    /// A collection made here that Kavita refused, or that couldn't be made again: it goes, with
    /// the series that were to go in it and their jobs.
    public func dropCollection(_ collectionId: Int64) throws {
        try database.writer.write { db in
            guard let row = try CollectionRow.fetchOne(db, key: collectionId) else { return }
            try Self.cancelSeriesJobs(db, row)
            try CollectionSeriesRow.filter(Column("collectionId") == collectionId).deleteAll(db)
            try row.delete(db)
        }
    }

    /// The own collections this device knows by Kavita's id (a create adopts only one it doesn't).
    public func knownServerIds(account: String) throws -> Set<Int> {
        try database.reader.read {
            Set(try CollectionRow.filter(Column("account") == account).fetchAll($0).compactMap(\.serverId))
        }
    }

    /// The series rows of a collection still to be sent.
    public func pendingSeries(collectionId: Int64) throws -> [CollectionSeriesRow] {
        try database.reader.read {
            try CollectionSeriesRow.filter(Column("collectionId") == collectionId && [CollectionSeriesRow.State.pendingAdd.rawValue,
                CollectionSeriesRow.State.pendingRemove.rawValue].contains(Column("state"))).fetchAll($0)
        }
    }

    // MARK: From the server

    /// One of Kavita's collections, as listed.
    public struct Listed: Equatable, Sendable {
        public var serverId: Int
        public var title: String
        public var isOwn: Bool
        public var owner: String?
        public var promoted: Bool
        public var source: Int
        public var itemCount: Int

        public init(serverId: Int, title: String, isOwn: Bool, owner: String?, promoted: Bool, source: Int, itemCount: Int) {
            self.serverId = serverId
            self.title = title
            self.isOwn = isOwn
            self.owner = owner
            self.promoted = promoted
            self.source = source
            self.itemCount = itemCount
        }
    }

    /// Kavita's list of collections, fetched at `listedAt`. A New Collection or a deletion still
    /// waiting stays (and one that lost its job follows the list); a collection Kavita no longer
    /// lists goes, with its series.
    public func merge(_ listed: [Listed], account: String, listedAt: Date? = nil) throws {
        try database.writer.write { db in
            let queued = try OutboxStore.queuedKeys(db, kind: .kavitaCollection)
            let rows = try CollectionRow.filter(Column("account") == account).fetchAll(db)
            func waiting(_ row: CollectionRow) -> Bool {
                row.state != .synced && row.id.map { queued.contains(CollectionJob(account: account, collectionId: $0).coalesceKey) } == true
            }
            let byServerId = Dictionary(listed.map { ($0.serverId, $0) }, uniquingKeysWith: { first, _ in first })
            for row in rows where !waiting(row) {
                if let serverId = row.serverId, byServerId[serverId] != nil { continue }
                if row.state == .synced, let listedAt, row.updatedAt > listedAt { continue }
                try CollectionSeriesRow.filter(Column("collectionId") == row.id).deleteAll(db)
                try row.delete(db)
            }
            let known = Dictionary(rows.compactMap { row in row.serverId.map { ($0, row) } }, uniquingKeysWith: { first, _ in first })
            // A New Collection whose create reached Kavita but whose answer didn't: the listed one
            // with its title is it (its create job then finds it made and sends nothing).
            var creating = rows.filter { $0.state == .pendingCreate && $0.serverId == nil && waiting($0) }
            for (position, item) in listed.enumerated() {
                var row: CollectionRow
                if let existing = known[item.serverId] {
                    row = existing
                    if row.id != nil, waiting(row) { continue }
                } else if item.isOwn, let index = creating.firstIndex(where: { CollectionRow.normalized($0.title) == CollectionRow.normalized(item.title) }) {
                    row = creating.remove(at: index)
                    row.serverId = item.serverId
                } else {
                    row = CollectionRow(account: account, serverId: item.serverId, title: item.title, state: .synced, updatedAt: now())
                }
                row.title = item.title
                row.isOwn = item.isOwn
                row.owner = item.owner
                row.promoted = item.promoted
                row.source = item.source
                row.itemCount = item.itemCount
                row.position = position
                row.state = .synced
                // Only a series in it confirms it (an empty one may be Kavita's to clean up).
                row.confirmed = row.confirmed || item.itemCount > 0
                try row.save(db)
            }
        }
    }

    /// A collection's series as Kavita listed them at `listedAt` (all pages). Adds and removes
    /// still waiting stay, and so do ones Kavita took after the list was fetched.
    public func mergeSeries(_ seriesIds: [Int], collectionId: Int64, listedAt: Date? = nil) throws {
        try database.writer.write { db in
            guard let collection = try CollectionRow.fetchOne(db, key: collectionId) else { return }
            let queued = try OutboxStore.queuedKeys(db, kind: .kavitaCollection)
            let rows = try CollectionSeriesRow.filter(Column("collectionId") == collectionId).fetchAll(db)
            func kept(_ row: CollectionSeriesRow) -> Bool {
                let pending = row.state == .pendingAdd || row.state == .pendingRemove
                if pending {
                    return queued.contains(CollectionJob(account: collection.account, collectionId: collectionId, seriesId: row.seriesId).coalesceKey)
                }
                return listedAt.map { row.updatedAt > $0 } == true
            }
            let listed = Set(seriesIds)
            for var row in rows where !listed.contains(row.seriesId) {
                if kept(row) {
                    // Waiting: Kavita doesn't have it (yet), as this list says.
                    if row.inKavita, row.state != .synced, row.state != .removed { row.inKavita = false; try row.update(db) }
                    continue
                }
                try row.delete(db)
            }
            for seriesId in listed {
                if var row = rows.first(where: { $0.seriesId == seriesId }), kept(row) {
                    if !row.inKavita, row.state == .pendingAdd || row.state == .pendingRemove { row.inKavita = true; try row.update(db) }
                    continue
                }
                try CollectionSeriesRow(collectionId: collectionId, seriesId: seriesId, state: .synced, inKavita: true, updatedAt: now()).save(db)
            }
            // The whole list was read: Kavita's count is its length.
            var read = collection
            read.seriesReadAt = now()
            read.itemCount = seriesIds.count
            try read.update(db)
        }
    }

    /// Which own collections hold a series, as Kavita answered (the series sheet asks when it
    /// opens), with the same rules as `mergeSeries`: a waiting change stays (Kavita's side is
    /// noted), and so does one Kavita took after the answer.
    public func mergeMembership(_ serverIds: Set<Int>, seriesId: Int, account: String, listedAt: Date? = nil) throws {
        try database.writer.write { db in
            let queued = try OutboxStore.queuedKeys(db, kind: .kavitaCollection)
            for collection in try CollectionRow.filter(Column("account") == account && Column("isOwn") == true).fetchAll(db) {
                guard let id = collection.id, let serverId = collection.serverId else { continue }
                let inKavita = serverIds.contains(serverId)
                if var row = try CollectionSeriesRow.fetchOne(db, key: ["collectionId": id, "seriesId": seriesId]) {
                    let pending = row.state == .pendingAdd || row.state == .pendingRemove
                    if pending, queued.contains(CollectionJob(account: account, collectionId: id, seriesId: seriesId).coalesceKey) {
                        row.inKavita = inKavita
                        try row.update(db)
                        continue
                    }
                    if !pending, let listedAt, row.updatedAt > listedAt { continue }
                    if inKavita {
                        row.state = .synced
                        row.inKavita = true
                        row.updatedAt = now()
                        try row.update(db)
                    } else {
                        try row.delete(db)
                    }
                } else if inKavita {
                    try CollectionSeriesRow(collectionId: id, seriesId: seriesId, state: .synced, inKavita: true, updatedAt: now()).insert(db)
                }
            }
        }
    }
}
