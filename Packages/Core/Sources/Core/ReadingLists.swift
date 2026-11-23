import Foundation
import GRDB

/// A Kavita reading list as this device knows it (per Kavita account): Kavita's list, plus a new
/// list or a deletion not sent yet.
public struct ReadingListRow: Codable, Equatable, Hashable, Sendable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "kavitaReadingList"

    public enum State: String, Codable, Sendable, DatabaseValueConvertible {
        case synced, pendingCreate, pendingDelete
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
    /// Synced from outside Kavita (a CBL list that syncs): read-only.
    public var isSynced: Bool
    /// How many items Kavita has, as last known (its list, a read of the items, or the adds and
    /// removes it took from here). Nil when Kavita didn't say (before 0.8.4).
    public var kavitaItemCount: Int?
    public var position: Int
    public var state: State
    /// How often the create was sent again because Kavita had cleaned up the empty list.
    public var createAttempts: Int
    /// When its items were last read from Kavita (their order and ids are known since then).
    public var itemsReadAt: Date?
    /// Kavita took an add or remove since the items were read: their ids and order need reading.
    public var itemsStale: Bool
    public var revision: Int
    public var updatedAt: Date

    public init(id: Int64? = nil, account: String, serverId: Int? = nil, title: String, isOwn: Bool = true, owner: String? = nil,
                promoted: Bool = false, isSynced: Bool = false, kavitaItemCount: Int? = 0, position: Int = 0, state: State,
                createAttempts: Int = 0, itemsReadAt: Date? = nil, itemsStale: Bool = false, revision: Int = 0, updatedAt: Date) {
        self.id = id
        self.account = account
        self.serverId = serverId
        self.title = title
        self.isOwn = isOwn
        self.owner = owner
        self.promoted = promoted
        self.isSynced = isSynced
        self.kavitaItemCount = kavitaItemCount
        self.position = position
        self.state = state
        self.createAttempts = createAttempts
        self.itemsReadAt = itemsReadAt
        self.itemsStale = itemsStale
        self.revision = revision
        self.updatedAt = updatedAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    /// Items can be added, taken out and moved, and it can be deleted, from Yomu.
    public var isEditable: Bool { isOwn && !isSynced }
}

/// A chapter in a reading list (a chapter is in a list at most once: Kavita skips one that is).
public struct ReadingListItemRow: Codable, Equatable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "kavitaReadingListItem"

    public enum State: String, Codable, Sendable, DatabaseValueConvertible {
        case synced, pendingAdd, pendingRemove
        /// Taken out on Kavita by this device: kept until a later read no longer differs.
        case removed
    }

    public var listId: Int64
    public var chapterId: Int
    /// Kavita's item id, once read (an unsent add has none).
    public var serverItemId: Int?
    public var seriesId: Int
    public var volumeId: Int
    public var libraryId: Int
    /// Kavita's series format (1 archive, 3 EPUB; 0 images and 4 PDF Yomu can't open).
    public var format: Int
    public var seriesName: String
    public var title: String
    /// Its place on Kavita as last read.
    public var kavitaOrder: Int
    public var state: State
    /// Whether Kavita has it, as last known.
    public var inKavita: Bool
    public var revision: Int
    public var updatedAt: Date

    public init(listId: Int64, chapterId: Int, serverItemId: Int? = nil, seriesId: Int, volumeId: Int, libraryId: Int, format: Int,
                seriesName: String, title: String, kavitaOrder: Int = .max, state: State, inKavita: Bool, revision: Int = 0, updatedAt: Date) {
        self.listId = listId
        self.chapterId = chapterId
        self.serverItemId = serverItemId
        self.seriesId = seriesId
        self.volumeId = volumeId
        self.libraryId = libraryId
        self.format = format
        self.seriesName = seriesName
        self.title = title
        self.kavitaOrder = kavitaOrder
        self.state = state
        self.inKavita = inKavita
        self.revision = revision
        self.updatedAt = updatedAt
    }

    public var isIn: Bool { state == .synced || state == .pendingAdd }
}

/// A move made here and not sent yet: the chapter goes right after the first of `anchors` that
/// Kavita still has (nearest first, as the list stood when it was made), or first.
public struct ReadingListMoveRow: Codable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "kavitaReadingListMove"

    public var id: Int64?
    public var listId: Int64
    public var chapterId: Int
    /// JSON array of chapter ids.
    public var anchors: String
    public var createdAt: Date

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public var anchorChapters: [Int] {
        (try? JSONDecoder().decode([Int].self, from: Data(anchors.utf8))) ?? []
    }
}

/// The outbox job for a reading list: its create or delete, one item's add or remove, or one move.
public struct ReadingListJob: Codable, Equatable, Sendable {
    public var account: String
    public var listId: Int64
    public var chapterId: Int?
    public var moveId: Int64?

    public init(account: String, listId: Int64, chapterId: Int? = nil, moveId: Int64? = nil) {
        self.account = account
        self.listId = listId
        self.chapterId = chapterId
        self.moveId = moveId
    }

    public var coalesceKey: String {
        let base = "readingList:\(account):\(listId)"
        if let moveId { return base + ":move:\(moveId)" }
        if let chapterId { return base + ":item:\(chapterId)" }
        return base
    }
}

/// What comes next in a reading list (`ReadingListStore.next`). `skipped` holds the reason for
/// each item passed over, in order.
public enum ReadingListNext: Equatable, Sendable {
    case item(ReadingListItemRow, skipped: [String])
    case end(skipped: [String])
    case notInList
}

public enum ReadingListError: Error, Equatable, LocalizedError {
    case readOnly(String)
    case emptyTitle
    case titleTaken(String)

    public var errorDescription: String? {
        switch self {
        case .readOnly(let title): "\u{201C}\(title)\u{201D} can't be changed from Yomu."
        case .emptyTitle: "A reading list needs a title."
        case .titleTaken(let title): "You already have a reading list called \u{201C}\(title)\u{201D}."
        }
    }
}

/// What the device knows of a chapter it adds (shown until Kavita's items are read back).
public struct ReadingListChapter: Equatable, Sendable {
    public var chapterId, seriesId, volumeId, libraryId, format: Int
    public var seriesName, title: String

    public init(chapterId: Int, seriesId: Int, volumeId: Int, libraryId: Int, format: Int, seriesName: String, title: String) {
        self.chapterId = chapterId
        self.seriesId = seriesId
        self.volumeId = volumeId
        self.libraryId = libraryId
        self.format = format
        self.seriesName = seriesName
        self.title = title
    }
}

public struct ReadingListStore: Sendable {
    public let database: AppDatabase
    let now: @Sendable () -> Date

    public init(database: AppDatabase, now: @escaping @Sendable () -> Date = Date.init) {
        self.database = database
        self.now = now
    }

    // MARK: Reading

    public func observe(account: String) -> AsyncThrowingStream<[ReadingListRow], any Error> {
        database.values { try Self.lists($0, account: account) }
    }

    public func lists(account: String) throws -> [ReadingListRow] {
        try database.reader.read { try Self.lists($0, account: account) }
    }

    static func lists(_ db: Database, account: String) throws -> [ReadingListRow] {
        let rows = try ReadingListRow.filter(Column("account") == account && Column("state") != ReadingListRow.State.pendingDelete).fetchAll(db)
        return rows.filter { $0.state == .pendingCreate }.sorted { $0.updatedAt > $1.updatedAt }
            + rows.filter { $0.state == .synced }.sorted { $0.position < $1.position }
    }

    public func list(_ id: Int64) throws -> ReadingListRow? {
        try database.reader.read { try ReadingListRow.fetchOne($0, key: id) }
    }

    public func item(listId: Int64, chapterId: Int) throws -> ReadingListItemRow? {
        try database.reader.read { try ReadingListItemRow.fetchOne($0, key: ["listId": listId, "chapterId": chapterId]) }
    }

    /// The list's items in the order the device shows them: Kavita's order from the last read,
    /// unsent adds at the end (where Kavita puts them), then the waiting moves applied in order.
    public func observeItems(listId: Int64) -> AsyncThrowingStream<[ReadingListItemRow], any Error> {
        database.values { try Self.items($0, listId: listId) }
    }

    public func items(listId: Int64) throws -> [ReadingListItemRow] {
        try database.reader.read { try Self.items($0, listId: listId) }
    }

    static func items(_ db: Database, listId: Int64) throws -> [ReadingListItemRow] {
        let rows = try ReadingListItemRow.filter(Column("listId") == listId).fetchAll(db).filter(\.isIn)
        let moves = try ReadingListMoveRow.filter(Column("listId") == listId).order(Column("id")).fetchAll(db)
        let order = Self.displayOrder(rows, moves: moves)
        let byChapter = Dictionary(rows.map { ($0.chapterId, $0) }, uniquingKeysWith: { first, _ in first })
        return order.compactMap { byChapter[$0] }
    }

    /// Kavita's order (adds after it), then each move: the chapter taken out and put right after
    /// its first anchor still in the list, or first.
    public static func displayOrder(_ rows: [ReadingListItemRow], moves: [ReadingListMoveRow]) -> [Int] {
        let known = rows.filter { $0.inKavita }.sorted { ($0.kavitaOrder, $0.chapterId) < ($1.kavitaOrder, $1.chapterId) }
        let added = rows.filter { !$0.inKavita }.sorted { $0.updatedAt < $1.updatedAt }
        var order = (known + added).map(\.chapterId)
        for move in moves { order = apply(move.chapterId, after: move.anchorChapters, to: order) }
        return order
    }

    /// `chapter` moved right after the first of `anchors` in `order` (or first). Unchanged when
    /// the chapter isn't there.
    public static func apply(_ chapter: Int, after anchors: [Int], to order: [Int]) -> [Int] {
        guard let from = order.firstIndex(of: chapter) else { return order }
        var order = order
        order.remove(at: from)
        let at = anchors.lazy.compactMap { order.firstIndex(of: $0) }.first.map { $0 + 1 } ?? 0
        order.insert(chapter, at: at)
        return order
    }

    /// How many items the list will have once this device's changes are sent, or nil when it
    /// can't be told (Kavita didn't say, or the items read earlier don't add up to its count).
    public func itemCount(listId: Int64) throws -> Int? {
        try database.reader.read { db in
            guard let list = try ReadingListRow.fetchOne(db, key: listId), let count = list.kavitaItemCount else { return nil }
            let rows = try ReadingListItemRow.filter(Column("listId") == listId).fetchAll(db)
            if list.itemsReadAt != nil, !list.itemsStale, rows.filter(\.inKavita).count != count { return nil }
            let unsent = rows.filter { $0.state == .pendingAdd || $0.state == .pendingRemove }
                .reduce(0) { $0 + ($1.isIn ? 1 : 0) - ($1.inKavita ? 1 : 0) }
            return max(0, count + unsent)
        }
    }

    // MARK: Reading in list order

    /// What comes after `chapterId` in a list, from the device's copy (works offline): Kavita's
    /// order with the waiting moves applied, unsent adds included, items being taken out left
    /// out. `skip` names why Yomu can never open an item here (nil: it can); those are passed
    /// over and counted. The item read isn't in the list (any more), or the list is gone:
    /// `.notInList`.
    public func next(after chapterId: Int, listId: Int64, skip: (ReadingListItemRow) -> String?) throws -> ReadingListNext {
        let (list, items) = try database.reader.read { db in
            (try ReadingListRow.fetchOne(db, key: listId), try Self.items(db, listId: listId))
        }
        guard let list, list.state != .pendingDelete, let index = items.firstIndex(where: { $0.chapterId == chapterId }) else { return .notInList }
        var skipped: [String] = []
        for item in items[(index + 1)...] {
            if let reason = skip(item) {
                skipped.append(reason)
            } else {
                return .item(item, skipped: skipped)
            }
        }
        return .end(skipped: skipped)
    }

    // MARK: Changes made here (each in one write with its job)

    @discardableResult
    public func create(title raw: String, with chapter: ReadingListChapter, account: String, outbox: OutboxStore) throws -> ReadingListRow {
        let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !CollectionRow.normalized(title).isEmpty else { throw ReadingListError.emptyTitle }
        return try database.writer.write { db in
            let taken = try Self.lists(db, account: account).filter(\.isOwn)
                .contains { CollectionRow.normalized($0.title) == CollectionRow.normalized(title) }
            guard !taken else { throw ReadingListError.titleTaken(title) }
            var row = ReadingListRow(account: account, title: title, state: .pendingCreate, updatedAt: now())
            try row.insert(db)
            try queue(ReadingListJob(account: account, listId: row.id!), outbox: outbox, in: db)
            try Self.itemRow(row.id!, chapter, now: now()).insert(db)
            try queue(ReadingListJob(account: account, listId: row.id!, chapterId: chapter.chapterId), outbox: outbox, in: db)
            return row
        }
    }

    static func itemRow(_ listId: Int64, _ chapter: ReadingListChapter, now: Date) -> ReadingListItemRow {
        ReadingListItemRow(listId: listId, chapterId: chapter.chapterId, seriesId: chapter.seriesId, volumeId: chapter.volumeId,
                           libraryId: chapter.libraryId, format: chapter.format, seriesName: chapter.seriesName, title: chapter.title,
                           state: .pendingAdd, inKavita: false, revision: 1, updatedAt: now)
    }

    /// Adds the chapter, or takes it out. Taking out an add not sent yet cancels it.
    public func set(_ inList: Bool, chapter: ReadingListChapter, listId: Int64, outbox: OutboxStore) throws {
        try database.writer.write { db in
            guard let list = try ReadingListRow.fetchOne(db, key: listId), list.state != .pendingDelete else { return }
            guard list.isEditable else { throw ReadingListError.readOnly(list.title) }
            var row = try ReadingListItemRow.fetchOne(db, key: ["listId": listId, "chapterId": chapter.chapterId])
                ?? Self.itemRow(listId, chapter, now: now()).with { $0.state = .removed; $0.revision = 0 }
            guard row.isIn != inList else { return }
            row.state = inList ? .pendingAdd : .pendingRemove
            row.revision += 1
            row.updatedAt = now()
            if !inList, !row.inKavita {
                // Never reached Kavita: nothing to send (its job, if still waiting, goes).
                try OutboxStore.cancel(db, coalesceKeys: [ReadingListJob(account: list.account, listId: listId, chapterId: row.chapterId).coalesceKey])
                try row.delete(db)
                return
            }
            try row.save(db)
            try queue(ReadingListJob(account: list.account, listId: listId, chapterId: row.chapterId), outbox: outbox, in: db)
        }
    }

    /// Moves a chapter to just after another (nil: first), as the list is shown now. The fallback
    /// chain (the items before it, nearest first) is kept with the move.
    public func move(_ chapterId: Int, after previous: Int?, listId: Int64, outbox: OutboxStore) throws {
        try database.writer.write { db in
            guard let list = try ReadingListRow.fetchOne(db, key: listId), list.state != .pendingDelete else { return }
            guard list.isEditable else { throw ReadingListError.readOnly(list.title) }
            let shown = try Self.items(db, listId: listId).map(\.chapterId)
            guard shown.contains(chapterId) else { return }
            var after = shown.filter { $0 != chapterId }
            if let previous, let index = after.firstIndex(of: previous) {
                after = Array(after[...index])
            } else {
                after = []
            }
            let anchors = String(decoding: try JSONEncoder().encode(Array(after.reversed())), as: UTF8.self)
            // The same chapter moved again with nothing queued for the list in between: the move
            // is updated (one request); otherwise a new one, so the order of moves is kept.
            let keys = try OutboxStore.pendingKeys(db, kind: .kavitaReadingList)
            if var last = try ReadingListMoveRow.filter(Column("listId") == listId).order(Column("id").desc).fetchOne(db),
               last.chapterId == chapterId,
               keys.contains(ReadingListJob(account: list.account, listId: listId, moveId: last.id).coalesceKey),
               try Self.lastQueuedKey(db, account: list.account, listId: listId) == ReadingListJob(account: list.account, listId: listId, moveId: last.id).coalesceKey {
                last.anchors = anchors
                try last.update(db)
                return
            }
            var row = ReadingListMoveRow(listId: listId, chapterId: chapterId, anchors: anchors, createdAt: now())
            try row.insert(db)
            try queue(ReadingListJob(account: list.account, listId: listId, moveId: row.id), outbox: outbox, in: db)
        }
    }

    /// The coalesce key of the list's most recently queued job still waiting.
    static func lastQueuedKey(_ db: Database, account: String, listId: Int64) throws -> String? {
        let prefix = ReadingListJob(account: account, listId: listId).coalesceKey
        return try String.fetchOne(db, sql: """
            SELECT coalesceKey FROM outboxJob WHERE kind = ? AND state = 'pending' AND (coalesceKey = ? OR coalesceKey LIKE ?)
            ORDER BY createdAt DESC, id DESC LIMIT 1
            """, arguments: [OutboxJobKind.kavitaReadingList.rawValue, prefix, prefix + ":%"])
    }

    /// Deletes the list: gone here at once, with its waiting changes.
    public func delete(_ listId: Int64, outbox: OutboxStore) throws {
        try database.writer.write { db in
            guard var list = try ReadingListRow.fetchOne(db, key: listId) else { return }
            guard list.isEditable else { throw ReadingListError.readOnly(list.title) }
            try Self.cancelItemJobs(db, list)
            try ReadingListItemRow.filter(Column("listId") == listId).deleteAll(db)
            try ReadingListMoveRow.filter(Column("listId") == listId).deleteAll(db)
            if list.serverId == nil {
                try OutboxStore.cancel(db, coalesceKeys: [ReadingListJob(account: list.account, listId: listId).coalesceKey])
                try list.delete(db)
                return
            }
            list.state = .pendingDelete
            list.revision += 1
            list.updatedAt = now()
            try list.update(db)
            try queue(ReadingListJob(account: list.account, listId: listId), outbox: outbox, in: db)
        }
    }

    private static func cancelItemJobs(_ db: Database, _ list: ReadingListRow) throws {
        guard let id = list.id else { return }
        let items = try ReadingListItemRow.filter(Column("listId") == id).fetchAll(db)
            .map { ReadingListJob(account: list.account, listId: id, chapterId: $0.chapterId).coalesceKey }
        let moves = try ReadingListMoveRow.filter(Column("listId") == id).fetchAll(db)
            .map { ReadingListJob(account: list.account, listId: id, moveId: $0.id).coalesceKey }
        try OutboxStore.cancel(db, coalesceKeys: items + moves)
    }

    func queue(_ job: ReadingListJob, outbox: OutboxStore, in db: Database) throws {
        try outbox.enqueue(job, kind: .kavitaReadingList, coalesceKey: job.coalesceKey, in: db)
    }

    // MARK: For the outbox handler

    public func isQueued(_ job: ReadingListJob) throws -> Bool {
        try database.reader.read { try OutboxStore.queuedKeys($0, kind: .kavitaReadingList).contains(job.coalesceKey) }
    }

    /// Whether an add or move of the list queued before this job is still to be sent (waiting or
    /// being sent; one that failed for good doesn't count).
    public func hasEarlierChange(account: String, listId: Int64, before jobId: Int64?) throws -> Bool {
        guard let jobId else { return false }
        let prefix = ReadingListJob(account: account, listId: listId).coalesceKey
        return try database.reader.read { db in
            try Bool.fetchOne(db, sql: """
                SELECT EXISTS (SELECT 1 FROM outboxJob o WHERE o.kind = ? AND o.state IN ('pending', 'inFlight') AND o.id < ?
                  AND (o.coalesceKey LIKE ? OR (o.coalesceKey LIKE ? AND EXISTS (SELECT 1 FROM kavitaReadingListItem i
                    WHERE i.listId = ? AND i.state = 'pendingAdd' AND o.coalesceKey = ? || i.chapterId))))
                """, arguments: [OutboxJobKind.kavitaReadingList.rawValue, jobId, prefix + ":move:%", prefix + ":item:%", listId, prefix + ":item:"]) ?? false
        }
    }

    public func moveRow(_ id: Int64) throws -> ReadingListMoveRow? {
        try database.reader.read { try ReadingListMoveRow.fetchOne($0, key: id) }
    }

    public func dropMove(_ id: Int64) throws {
        _ = try database.writer.write { try ReadingListMoveRow.deleteOne($0, key: id) }
    }

    @discardableResult
    public func didCreate(_ listId: Int64, serverId: Int) throws -> Bool {
        try database.writer.write { db in
            guard var row = try ReadingListRow.fetchOne(db, key: listId) else { return false }
            guard row.state == .pendingCreate else { return true }
            row.serverId = serverId
            row.state = .synced
            row.kavitaItemCount = 0
            row.itemsStale = true
            row.updatedAt = now()
            try row.update(db)
            return true
        }
    }

    public func didDelete(_ listId: Int64) throws {
        try dropList(listId)
    }

    /// Kavita took an item's add or remove.
    public func didSend(_ sent: ReadingListItemRow) throws {
        try database.writer.write { db in
            guard var row = try ReadingListItemRow.fetchOne(db, key: ["listId": sent.listId, "chapterId": sent.chapterId]),
                  row.revision == sent.revision, row.state == .pendingAdd || row.state == .pendingRemove else { return }
            let added = row.state == .pendingAdd
            let wasIn = row.inKavita
            row.state = added ? .synced : .removed
            row.inKavita = added
            row.updatedAt = now()
            try row.update(db)
            if var list = try ReadingListRow.fetchOne(db, key: sent.listId) {
                list.kavitaItemCount = list.kavitaItemCount.map { max(0, $0 + (added ? 1 : 0) - (wasIn ? 1 : 0)) }
                list.itemsStale = true
                try list.update(db)
            }
        }
    }

    public func dropItem(_ row: ReadingListItemRow) throws {
        _ = try database.writer.write { try ReadingListItemRow.deleteOne($0, key: ["listId": row.listId, "chapterId": row.chapterId]) }
    }

    /// Kavita's cleanup removed the list while it was empty as last known (new, or emptied from
    /// here): it's made again with its waiting adds, in the same write as its create job, at most
    /// twice. False once that's been tried enough (or it had items, so it was deleted elsewhere).
    public func recreate(_ listId: Int64, outbox: OutboxStore) throws -> Bool {
        try database.writer.write { db in
            guard var row = try ReadingListRow.fetchOne(db, key: listId), row.kavitaItemCount == 0, row.createAttempts < 2 else { return false }
            row.serverId = nil
            row.state = .pendingCreate
            row.createAttempts += 1
            row.updatedAt = now()
            try row.update(db)
            // What Kavita had is gone with it: every row is now an add still to make.
            for var item in try ReadingListItemRow.filter(Column("listId") == listId).fetchAll(db) {
                item.inKavita = false
                item.serverItemId = nil
                try item.update(db)
            }
            try queue(ReadingListJob(account: row.account, listId: listId), outbox: outbox, in: db)
            return true
        }
    }

    /// The list goes from the device with its items, moves and their jobs.
    public func dropList(_ listId: Int64) throws {
        try database.writer.write { db in
            guard let row = try ReadingListRow.fetchOne(db, key: listId) else { return }
            try Self.cancelItemJobs(db, row)
            try ReadingListItemRow.filter(Column("listId") == listId).deleteAll(db)
            try ReadingListMoveRow.filter(Column("listId") == listId).deleteAll(db)
            try row.delete(db)
        }
    }

    public func knownServerIds(account: String) throws -> Set<Int> {
        try database.reader.read { Set(try ReadingListRow.filter(Column("account") == account).fetchAll($0).compactMap(\.serverId)) }
    }

    /// Whether the items as last read can stand in for reading them again (a run of moves reads
    /// them once).
    public func itemsAreFresh(_ listId: Int64, within seconds: TimeInterval = 60) throws -> Bool {
        guard let list = try list(listId), let read = list.itemsReadAt else { return false }
        return !list.itemsStale && now().timeIntervalSince(read) < seconds
    }

    /// Kavita moved a chapter: its order here follows, so the next move needs no read.
    public func didMove(_ moveId: Int64, kavitaOrder: [Int], listId: Int64) throws {
        try database.writer.write { db in
            for (index, chapterId) in kavitaOrder.enumerated() {
                guard var row = try ReadingListItemRow.fetchOne(db, key: ["listId": listId, "chapterId": chapterId]) else { continue }
                row.kavitaOrder = index
                try row.update(db)
            }
            _ = try ReadingListMoveRow.deleteOne(db, key: moveId)
        }
    }

    /// The items Kavita has, in its order (as last read), with their ids.
    public func kavitaItems(listId: Int64) throws -> [(chapterId: Int, serverItemId: Int?)] {
        try database.reader.read { db in
            try ReadingListItemRow.filter(Column("listId") == listId).fetchAll(db).filter(\.inKavita)
                .sorted { $0.kavitaOrder < $1.kavitaOrder }.map { ($0.chapterId, $0.serverItemId) }
        }
    }

    // MARK: From the server

    public struct Listed: Equatable, Sendable {
        public var serverId: Int
        public var title: String
        public var isOwn: Bool
        public var owner: String?
        public var promoted: Bool
        public var isSynced: Bool
        public var itemCount: Int?

        public init(serverId: Int, title: String, isOwn: Bool, owner: String?, promoted: Bool, isSynced: Bool, itemCount: Int?) {
            self.serverId = serverId
            self.title = title
            self.isOwn = isOwn
            self.owner = owner
            self.promoted = promoted
            self.isSynced = isSynced
            self.itemCount = itemCount
        }
    }

    /// Kavita's lists, fetched at `listedAt`, with the rules collections have: a waiting create
    /// or delete stays (one that lost its job follows the list), a listed own list with a waiting
    /// create's title is that list, one Kavita no longer lists goes.
    public func merge(_ listed: [Listed], account: String, listedAt: Date? = nil) throws {
        try database.writer.write { db in
            let queued = try OutboxStore.queuedKeys(db, kind: .kavitaReadingList)
            let sending = try OutboxStore.sendingKeys(db, kind: .kavitaReadingList)
            let rows = try ReadingListRow.filter(Column("account") == account).fetchAll(db)
            func waiting(_ row: ReadingListRow) -> Bool {
                row.state != .synced && row.id.map { queued.contains(ReadingListJob(account: account, listId: $0).coalesceKey) } == true
            }
            /// Empty as last known with an add still to send: Kavita's cleanup may have taken it,
            /// and the add's job makes it again (it's left to the handler).
            func emptiedWithAdd(_ row: ReadingListRow) throws -> Bool {
                guard row.kavitaItemCount == 0, let id = row.id else { return false }
                return try ReadingListItemRow.filter(Column("listId") == id && Column("state") == ReadingListItemRow.State.pendingAdd.rawValue)
                    .fetchAll(db).contains { sending.contains(ReadingListJob(account: account, listId: id, chapterId: $0.chapterId).coalesceKey) }
            }
            let byServerId = Set(listed.map(\.serverId))
            for row in rows where !waiting(row) {
                if let serverId = row.serverId, byServerId.contains(serverId) { continue }
                if row.state == .synced, let listedAt, row.updatedAt > listedAt { continue }
                if row.state == .synced, try emptiedWithAdd(row) { continue }
                if let id = row.id { try Self.dropRows(db, id) }
                try row.delete(db)
            }
            let known = Dictionary(rows.compactMap { row in row.serverId.map { ($0, row) } }, uniquingKeysWith: { first, _ in first })
            var creating = rows.filter { $0.state == .pendingCreate && $0.serverId == nil && waiting($0) }
            for (position, item) in listed.enumerated() {
                var row: ReadingListRow
                if let existing = known[item.serverId] {
                    row = existing
                    if waiting(row) { continue }
                } else if item.isOwn, let index = creating.firstIndex(where: { CollectionRow.normalized($0.title) == CollectionRow.normalized(item.title) }) {
                    row = creating.remove(at: index)
                    row.serverId = item.serverId
                    row.itemsStale = true
                } else {
                    row = ReadingListRow(account: account, serverId: item.serverId, title: item.title, state: .synced, updatedAt: now())
                }
                row.title = item.title
                row.isOwn = item.isOwn
                row.owner = item.owner
                row.promoted = item.promoted
                row.isSynced = item.isSynced
                row.kavitaItemCount = item.itemCount
                row.position = position
                row.state = .synced
                try row.save(db)
            }
        }
    }

    private static func dropRows(_ db: Database, _ listId: Int64) throws {
        try ReadingListItemRow.filter(Column("listId") == listId).deleteAll(db)
        try ReadingListMoveRow.filter(Column("listId") == listId).deleteAll(db)
    }

    /// One of Kavita's items, as read.
    public struct ListedItem: Equatable, Sendable {
        public var serverItemId: Int
        public var chapter: ReadingListChapter

        public init(serverItemId: Int, chapter: ReadingListChapter) {
            self.serverItemId = serverItemId
            self.chapter = chapter
        }
    }

    /// A list's items as Kavita has them (in its order), read at `listedAt`. Waiting adds and
    /// removes stay (Kavita's side noted), and so does one Kavita took after the read; moves
    /// whose jobs are gone go.
    public func mergeItems(_ listed: [ListedItem], listId: Int64, listedAt: Date? = nil) throws {
        try database.writer.write { db in
            guard var list = try ReadingListRow.fetchOne(db, key: listId) else { return }
            let queued = try OutboxStore.queuedKeys(db, kind: .kavitaReadingList)
            let rows = try ReadingListItemRow.filter(Column("listId") == listId).fetchAll(db)
            func waiting(_ row: ReadingListItemRow) -> Bool {
                (row.state == .pendingAdd || row.state == .pendingRemove)
                    && queued.contains(ReadingListJob(account: list.account, listId: listId, chapterId: row.chapterId).coalesceKey)
            }
            func newer(_ row: ReadingListItemRow) -> Bool {
                row.state != .pendingAdd && row.state != .pendingRemove && listedAt.map { row.updatedAt > $0 } == true
            }
            let byChapter = Dictionary(listed.enumerated().map { ($1.chapter.chapterId, ($0, $1)) }, uniquingKeysWith: { first, _ in first })
            // A row changed after the read (an add sent meanwhile) keeps what it has, so the read
            // doesn't count as fresh: the item's Kavita id isn't known from it.
            var skipped = false
            for var row in rows {
                let remote = byChapter[row.chapterId]
                if waiting(row) {
                    row.inKavita = remote != nil
                    row.serverItemId = remote?.1.serverItemId
                    row.kavitaOrder = remote?.0 ?? .max
                    try row.update(db)
                } else if newer(row) {
                    skipped = true
                    continue
                } else if remote == nil {
                    try row.delete(db)
                }
            }
            for (chapterId, (order, item)) in byChapter {
                if let row = rows.first(where: { $0.chapterId == chapterId }), waiting(row) || newer(row) { continue }
                var row = Self.itemRow(listId, item.chapter, now: now())
                row.serverItemId = item.serverItemId
                row.kavitaOrder = order
                row.state = .synced
                row.inKavita = true
                row.revision = 0
                try row.save(db)
            }
            for move in try ReadingListMoveRow.filter(Column("listId") == listId).fetchAll(db)
            where !queued.contains(ReadingListJob(account: list.account, listId: listId, moveId: move.id).coalesceKey) {
                try move.delete(db)
            }
            if !skipped { list.kavitaItemCount = listed.count }
            list.itemsReadAt = now()
            list.itemsStale = skipped
            try list.update(db)
        }
    }
}

extension ReadingListItemRow {
    func with(_ change: (inout Self) -> Void) -> Self {
        var copy = self
        change(&copy)
        return copy
    }
}
