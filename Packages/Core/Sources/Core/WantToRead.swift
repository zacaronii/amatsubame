import Foundation
import GRDB

/// A series in Kavita's Want to Read, as this device knows it (per Kavita account): Kavita's
/// list, plus the toggles not sent yet.
public struct WantToReadRow: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "wantToRead"

    public enum State: String, Codable, Sendable, DatabaseValueConvertible {
        case synced
        /// Added here, not on Kavita yet.
        case pendingAdd
        /// Removed here, not on Kavita yet.
        case pendingRemove
        /// Removed on Kavita by this device: kept until a list fetched after that no longer has it,
        /// so an older list doesn't bring it back.
        case removed
    }

    /// `ReaderMarkStore.accountKey` of the Kavita account.
    public var account: String
    public var seriesId: Int
    public var state: State
    /// Its place in Kavita's list (unsent additions come first, newest first).
    public var position: Int
    /// Goes up with every toggle here, so a send that raced another toggle can tell.
    public var revision: Int
    /// When it last changed here (a toggle, or Kavita taking one).
    public var updatedAt: Date

    public var isWanted: Bool { state == .synced || state == .pendingAdd }
}

/// The outbox job that brings one series' Want to Read on Kavita up to date with its row.
public struct WantToReadJob: Codable, Equatable, Sendable {
    public var account: String
    public var seriesId: Int

    public init(account: String, seriesId: Int) {
        self.account = account
        self.seriesId = seriesId
    }

    public var coalesceKey: String { "wantToRead:\(account):\(seriesId)" }
}

public struct WantToReadStore: Sendable {
    public let database: AppDatabase
    let now: @Sendable () -> Date

    public init(database: AppDatabase, now: @escaping @Sendable () -> Date = Date.init) {
        self.database = database
        self.now = now
    }

    /// The account's Want to Read series in the shelf's order: unsent additions first (newest
    /// first), then Kavita's order.
    public func observe(account: String) -> AsyncThrowingStream<[Int], any Error> {
        database.values { try Self.wanted($0, account: account) }
    }

    public func wanted(account: String) throws -> [Int] {
        try database.reader.read { try Self.wanted($0, account: account) }
    }

    static func wanted(_ db: Database, account: String) throws -> [Int] {
        let rows = try WantToReadRow.filter(Column("account") == account).fetchAll(db).filter(\.isWanted)
        let added = rows.filter { $0.state == .pendingAdd }.sorted { $0.updatedAt > $1.updatedAt }
        let listed = rows.filter { $0.state == .synced }.sorted { $0.position < $1.position }
        return (added + listed).map(\.seriesId)
    }

    public func row(account: String, seriesId: Int) throws -> WantToReadRow? {
        try database.reader.read { try WantToReadRow.fetchOne($0, key: ["account": account, "seriesId": seriesId]) }
    }

    /// Whether the series is in the account's Want to Read on this device.
    public func isWanted(account: String, seriesId: Int) throws -> Bool {
        try row(account: account, seriesId: seriesId)?.isWanted ?? false
    }

    /// Adds the series to Want to Read or removes it, at once here, and queues it for Kavita.
    public func set(_ wanted: Bool, seriesId: Int, account: String, outbox: OutboxStore) throws {
        let changed: Bool = try database.writer.write { db in
            var row = try WantToReadRow.fetchOne(db, key: ["account": account, "seriesId": seriesId])
                ?? WantToReadRow(account: account, seriesId: seriesId, state: .removed, position: 0, revision: 0, updatedAt: now())
            guard row.isWanted != wanted else { return false }
            row.state = wanted ? .pendingAdd : .pendingRemove
            row.revision += 1
            row.updatedAt = now()
            try row.save(db)
            return true
        }
        guard changed else { return }
        let job = WantToReadJob(account: account, seriesId: seriesId)
        try outbox.enqueue(job, kind: .kavitaWantToRead, coalesceKey: job.coalesceKey)
    }

    /// After Kavita took the toggle. A toggle made meanwhile keeps its own state (its job
    /// follows). Stamped, so a list fetched before this doesn't undo it.
    public func didSend(_ sent: WantToReadRow) throws {
        try database.writer.write { db in
            guard var row = try WantToReadRow.fetchOne(db, key: ["account": sent.account, "seriesId": sent.seriesId]),
                  row.revision == sent.revision else { return }
            row.state = row.state == .pendingRemove ? .removed : .synced
            row.updatedAt = now()
            try row.update(db)
        }
    }

    /// Rows whose toggle still has a job waiting for it (`WantToReadJob.coalesceKey`: waiting,
    /// sending, or failed and listed). A pending row without one (its job cleared in Waiting to
    /// Sync) no longer outranks Kavita.
    static func waiting(_ db: Database, _ rows: [WantToReadRow]) throws -> Set<Int> {
        let pending = rows.filter { $0.state == .pendingAdd || $0.state == .pendingRemove }
        guard !pending.isEmpty else { return [] }
        let keys = try OutboxStore.queuedKeys(db, kind: .kavitaWantToRead)
        return Set(pending.filter { keys.contains(WantToReadJob(account: $0.account, seriesId: $0.seriesId).coalesceKey) }.map(\.seriesId))
    }

    /// Kavita's whole list for the account, in its order, fetched at `listedAt`. Toggles still
    /// waiting to be sent stay as they are, and so does a toggle Kavita took after the list was
    /// fetched; everything else follows the list.
    public func merge(_ seriesIds: [Int], account: String, listedAt: Date? = nil) throws {
        try database.writer.write { db in
            let rows = Dictionary(try WantToReadRow.filter(Column("account") == account).fetchAll(db).map { ($0.seriesId, $0) },
                                  uniquingKeysWith: { first, _ in first })
            let listed = Dictionary(seriesIds.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
            let waiting = try Self.waiting(db, Array(rows.values))
            func kept(_ row: WantToReadRow) -> Bool {
                waiting.contains(row.seriesId) || (row.state != .pendingAdd && row.state != .pendingRemove && listedAt.map { row.updatedAt > $0 } == true)
            }
            for row in rows.values where !kept(row) && listed[row.seriesId] == nil { try row.delete(db) }
            for (seriesId, position) in listed {
                if let row = rows[seriesId], kept(row) { continue }
                var row = rows[seriesId]
                    ?? WantToReadRow(account: account, seriesId: seriesId, state: .synced, position: position, revision: 0, updatedAt: now())
                row.position = position
                row.state = .synced
                try row.save(db)
            }
        }
    }

    /// What Kavita says about one series, asked at `askedAt` (the series page, when it opens),
    /// unless a toggle of it is still waiting or was taken by Kavita since.
    public func note(_ wanted: Bool, seriesId: Int, account: String, askedAt: Date? = nil) throws {
        try database.writer.write { db in
            let row = try WantToReadRow.fetchOne(db, key: ["account": account, "seriesId": seriesId])
            if let row {
                if try !Self.waiting(db, [row]).isEmpty { return }
                if row.state == .synced || row.state == .removed, let askedAt, row.updatedAt > askedAt { return }
            }
            if wanted {
                var row = row ?? WantToReadRow(account: account, seriesId: seriesId, state: .synced, position: -1, revision: 0, updatedAt: now())
                row.state = .synced
                try row.save(db)
            } else if let row {
                try row.delete(db)
            }
        }
    }

    /// A server without Want to Read: the unsent toggles go (nothing typed is lost).
    public func dropUnsent(account: String) throws {
        _ = try database.writer.write {
            try WantToReadRow.filter(Column("account") == account && Column("state") != WantToReadRow.State.synced).deleteAll($0)
        }
    }
}
