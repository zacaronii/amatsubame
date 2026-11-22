import Foundation
import GRDB

/// A bookmark or highlight in Yomu, kept on Kavita: the server is the home of every mark, and
/// this row is the device's copy of it (for reading offline) plus what hasn't been sent yet.
public struct ReaderMark: Codable, Equatable, Hashable, Sendable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "readerMark"

    /// Where Kavita keeps it.
    public enum Kind: String, Codable, Sendable, DatabaseValueConvertible {
        /// A manga page (Kavita's page bookmarks; it keeps a copy of the page image).
        case pageBookmark
        /// A place in a book (Kavita's personal table of contents, its book reader's bookmarks).
        case bookBookmark
        /// Highlighted text in a book, with an optional note (Kavita's annotations).
        case highlight
    }

    /// Whether the server has it as this row says.
    public enum State: String, Codable, Sendable, DatabaseValueConvertible {
        case synced
        /// Made here, not on the server yet.
        case pendingCreate
        /// Changed here (note, colour), not sent yet.
        case pendingUpdate
        /// Removed here; the row goes once the server has removed it too.
        case pendingDelete
    }

    public var id: Int64?
    /// The Kavita server and user it belongs to (`ReaderMarkStore.accountKey`), so another
    /// account's marks never mix in.
    public var account: String
    public var kind: Kind
    /// Kavita's id (annotations, and the others once listed); nil until sent.
    public var serverId: Int?
    public var libraryId: Int
    public var seriesId: Int
    public var volumeId: Int
    public var chapterId: Int
    /// 0-based page: a manga page, or a book's page (spine item) as Kavita counts them.
    public var page: Int
    /// Books: Kavita's XPath of where it starts (and ends, for highlights).
    public var xpath: String?
    public var endXPath: String?
    /// Highlights: the text. Book bookmarks: the words they start at.
    public var text: String?
    /// Book bookmarks: Kavita's title (unique on its page).
    public var title: String?
    /// Highlights: the note (plain text).
    public var note: String?
    /// Highlights: Kavita's colour slot, 0–4.
    public var slot: Int
    public var state: State
    /// Goes up with every change made here, so a send that raced an edit can tell.
    public var revision: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: Int64? = nil, account: String, kind: Kind, serverId: Int? = nil, libraryId: Int, seriesId: Int, volumeId: Int,
                chapterId: Int, page: Int, xpath: String? = nil, endXPath: String? = nil, text: String? = nil, title: String? = nil,
                note: String? = nil, slot: Int = 0, state: State, revision: Int = 0, createdAt: Date, updatedAt: Date) {
        self.id = id
        self.account = account
        self.kind = kind
        self.serverId = serverId
        self.libraryId = libraryId
        self.seriesId = seriesId
        self.volumeId = volumeId
        self.chapterId = chapterId
        self.page = page
        self.xpath = xpath
        self.endXPath = endXPath
        self.text = text
        self.title = title
        self.note = note
        self.slot = slot
        self.state = state
        self.revision = revision
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    /// What identifies the mark on the server: Kavita deletes page bookmarks by page and book
    /// bookmarks by page and title; annotations have ids.
    public var serverKey: String? {
        switch kind {
        case .pageBookmark: "\(chapterId)/\(page)"
        case .bookBookmark: "\(chapterId)/\(page)/\(title ?? "")"
        case .highlight: serverId.map(String.init)
        }
    }
}

/// What Yomu knows a Kavita server can't do, so it stops offering it there instead of queueing
/// changes that would fail for ever.
public enum KavitaFeature: String, Codable, Sendable, DatabaseValueConvertible {
    /// Highlights and notes (Kavita 0.8.8 and later).
    case annotations
    /// Page bookmarks (the account needs Kavita's Bookmark role).
    case pageBookmarks
    /// Want to Read's list (Kavita 0.7.8 and later).
    case wantToRead
    /// Collections as Kavita 0.8.0 has them (own and promoted).
    case collections
}

struct KavitaFeatureRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "kavitaFeature"
    var account: String
    var feature: KavitaFeature
    var available: Bool
    var checkedAt: Date
}

/// The outbox job that brings one mark's server copy up to date with its row.
public struct ReaderMarkJob: Codable, Equatable, Sendable {
    public var markId: Int64
    public init(markId: Int64) {
        self.markId = markId
    }

    public var coalesceKey: String { "readerMark:\(markId)" }
}

public struct ReaderMarkStore: Sendable {
    public let database: AppDatabase
    let now: @Sendable () -> Date

    public init(database: AppDatabase, now: @escaping @Sendable () -> Date = Date.init) {
        self.database = database
        self.now = now
    }

    /// The account a Kavita login's marks belong to.
    public static func accountKey(_ account: ServerAccount) -> String {
        "\(account.baseURL.absoluteString)#\(account.username ?? account.userId ?? "")"
    }

    // MARK: Reading

    /// A series' marks, without the ones being removed, in reading order.
    public func observe(account: String, seriesId: Int) -> AsyncThrowingStream<[ReaderMark], any Error> {
        database.values { try Self.visible($0, account: account, seriesId: seriesId) }
    }

    public func marks(account: String, seriesId: Int) throws -> [ReaderMark] {
        try database.reader.read { try Self.visible($0, account: account, seriesId: seriesId) }
    }

    static func visible(_ db: Database, account: String, seriesId: Int) throws -> [ReaderMark] {
        try ReaderMark
            .filter(Column("account") == account && Column("seriesId") == seriesId && Column("state") != ReaderMark.State.pendingDelete)
            .order(Column("volumeId"), Column("chapterId"), Column("page"), Column("createdAt"))
            .fetchAll(db)
    }

    public func mark(_ id: Int64) throws -> ReaderMark? {
        try database.reader.read { try ReaderMark.fetchOne($0, key: id) }
    }

    // MARK: Changes made here (each one queued for the server)

    /// Adds a mark and queues it. Returns the row. Bookmarking a page again while its removal
    /// is still waiting takes that same row back, so there's never a removal and a make of the
    /// same bookmark in the queue at once (a retried removal could go after the make).
    @discardableResult
    public func add(_ mark: ReaderMark, outbox: OutboxStore) throws -> ReaderMark {
        var mark = mark
        let now = now()
        mark = try database.writer.write { db in
            if mark.kind != .highlight, let key = mark.serverKey,
               var waiting = try ReaderMark.filter(Column("account") == mark.account && Column("kind") == mark.kind
                                                   && Column("chapterId") == mark.chapterId && Column("state") == ReaderMark.State.pendingDelete)
                   .fetchAll(db).first(where: { $0.serverKey == key }) {
                waiting.state = .pendingCreate
                waiting.text = mark.text ?? waiting.text
                waiting.xpath = mark.xpath ?? waiting.xpath
                waiting.revision += 1
                waiting.updatedAt = now
                try waiting.update(db)
                try queue(waiting, outbox: outbox, in: db)
                return waiting
            }
            mark.id = nil
            mark.serverId = nil
            mark.state = .pendingCreate
            mark.revision = 0
            mark.createdAt = now
            mark.updatedAt = now
            try mark.insert(db)
            try queue(mark, outbox: outbox, in: db)
            return mark
        }
        return mark
    }

    /// Changes a highlight's note or colour.
    public func edit(_ id: Int64, note: String?, slot: Int, outbox: OutboxStore) throws {
        try database.writer.write { db in
            guard var mark = try ReaderMark.fetchOne(db, key: id), mark.state != .pendingDelete else { return }
            mark.note = note.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
            mark.slot = slot
            // An edit before the mark was sent goes with it when it's made.
            if mark.state == .synced { mark.state = .pendingUpdate }
            mark.revision += 1
            mark.updatedAt = now()
            try mark.update(db)
            try queue(mark, outbox: outbox, in: db)
        }
    }

    /// Removes a mark: hidden at once, gone from the server when the outbox has sent it.
    public func remove(_ id: Int64, outbox: OutboxStore) throws {
        try database.writer.write { db in
            guard var mark = try ReaderMark.fetchOne(db, key: id) else { return }
            mark.state = .pendingDelete
            mark.revision += 1
            mark.updatedAt = now()
            try mark.update(db)
            try queue(mark, outbox: outbox, in: db)
        }
    }

    /// Queues the mark's job in the same write as the row (`outbox` is on this database), so a
    /// refresh never sees a pending row without its job.
    func queue(_ mark: ReaderMark, outbox: OutboxStore, in db: Database) throws {
        guard let id = mark.id else { return }
        let job = ReaderMarkJob(markId: id)
        try outbox.enqueue(job, kind: .kavitaReaderMark, coalesceKey: job.coalesceKey, in: db)
    }

    // MARK: For the outbox handler

    /// After a create or update reached the server. If the row changed while it was being sent,
    /// it stays pending (its job comes next) but keeps the server's id.
    public func didSend(_ sent: ReaderMark, serverId: Int?) throws {
        guard let id = sent.id else { return }
        try database.writer.write { db in
            guard var row = try ReaderMark.fetchOne(db, key: id) else { return }
            row.serverId = serverId ?? row.serverId
            if row.revision == sent.revision {
                row.state = .synced
            } else if row.state == .pendingCreate {
                // Made, then edited before the make got there: the edit is an update now.
                row.state = .pendingUpdate
            }
            try row.update(db)
        }
    }

    /// Once the server no longer has it (or it never got there), the row goes, unless it was
    /// taken back meanwhile (bookmarked again): then its own job makes it again.
    public func didRemove(_ sent: ReaderMark) throws {
        guard let id = sent.id else { return }
        try database.writer.write { db in
            guard let row = try ReaderMark.fetchOne(db, key: id), row.revision == sent.revision || row.state == .pendingDelete else { return }
            try row.delete(db)
        }
    }

    /// Queues again the unsent marks of a kind (annotations found available after all).
    public func requeueUnsent(_ kind: ReaderMark.Kind, account: String, outbox: OutboxStore) throws {
        try database.writer.write { try requeueUnsent($0, kind, account: account, outbox: outbox) }
    }

    func requeueUnsent(_ db: Database, _ kind: ReaderMark.Kind, account: String, outbox: OutboxStore) throws {
        let marks = try ReaderMark.filter(Column("account") == account && Column("kind") == kind && Column("state") != ReaderMark.State.synced).fetchAll(db)
        for mark in marks { try queue(mark, outbox: outbox, in: db) }
    }

    // MARK: What the server can do

    public func isAvailable(_ feature: KavitaFeature, account: String) throws -> Bool {
        try database.reader.read {
            try KavitaFeatureRecord.fetchOne($0, key: ["account": account, "feature": feature.rawValue])?.available ?? true
        }
    }

    /// Records what the server answered. Unsent page bookmarks go when the account can't keep
    /// them (nothing typed is lost). Unsent highlights stay, with their notes, shown as not on
    /// Kavita yet: they're queued again when the server is found to have annotations (`outbox`).
    public func setAvailable(_ available: Bool, _ feature: KavitaFeature, account: String, outbox: OutboxStore? = nil) throws {
        try database.writer.write { db in
            let wasAvailable = try KavitaFeatureRecord.fetchOne(db, key: ["account": account, "feature": feature.rawValue])?.available ?? true
            try KavitaFeatureRecord(account: account, feature: feature, available: available, checkedAt: now()).save(db)
            // In the same write, so a refresh never sees the kept highlights without their jobs.
            if available, !wasAvailable, feature == .annotations, let outbox {
                try requeueUnsent(db, .highlight, account: account, outbox: outbox)
            }
            guard !available, feature == .pageBookmarks else { return }
            try ReaderMark.filter(Column("account") == account && Column("kind") == ReaderMark.Kind.pageBookmark
                                  && Column("state") != ReaderMark.State.synced).deleteAll(db)
        }
    }

    // MARK: From the server

    /// Brings the rows of `kinds` in `scope` up to date with what the server listed for it.
    /// `scope` decides which local rows the listing covers (a series, or some chapters).
    /// Returns the marks that need a job (ones to make again because they were removed on
    /// another device while edited here).
    @discardableResult
    public func merge(_ server: [ReaderMark], account: String, kinds: Set<ReaderMark.Kind>,
                      scope: (ReaderMark) -> Bool, outbox: OutboxStore) throws -> [ReaderMark] {
        let requeue: [ReaderMark] = try database.writer.write { db in
            // A change whose job was cleared in Waiting to Sync ("they won't reach the server")
            // no longer outranks the server's list: it's taken as what the server last had.
            let queued = try OutboxStore.queuedKeys(db, kind: .kavitaReaderMark)
            let local = try ReaderMark.filter(Column("account") == account).fetchAll(db)
                .filter { kinds.contains($0.kind) && scope($0) }
                .map { mark in
                    guard mark.state != .synced, let id = mark.id, !queued.contains(ReaderMarkJob(markId: id).coalesceKey) else { return mark }
                    var settled = mark
                    settled.state = .synced
                    return settled
                }
            let plan = ReaderMarkMerge.plan(local: local, server: server.filter { kinds.contains($0.kind) })
            for id in plan.delete { try ReaderMark.deleteOne(db, key: id) }
            for var mark in plan.save {
                mark.account = account
                try mark.save(db)
            }
            let again = plan.save.filter { $0.state == .pendingCreate && plan.recreated.contains($0.id ?? -1) }
            for mark in again { try queue(mark, outbox: outbox, in: db) }
            return again
        }
        return requeue
    }
}

/// How the server's list and the device's rows come together (pure, so it can be tested).
public enum ReaderMarkMerge {
    public struct Plan: Equatable {
        public var save: [ReaderMark] = []
        public var delete: [Int64] = []
        /// Rows edited here whose server copy was removed elsewhere: made again.
        public var recreated: [Int64] = []
    }

    /// - The server's copy replaces a synced row; one only on the server is added.
    /// - A synced row the server no longer has was removed on another device: it goes.
    /// - Changes not sent yet stay, and are sent: an edit to a mark removed elsewhere makes
    ///   it again (the newest intent), a removal of one already gone just finishes.
    /// - A mark made here that the server turns out to have already (the same page bookmarked
    ///   on two devices) is the server's.
    public static func plan(local: [ReaderMark], server: [ReaderMark]) -> Plan {
        var plan = Plan()
        var serverByKey: [String: ReaderMark] = [:]
        for mark in server { if let key = mark.serverKey { serverByKey[key] = mark } }
        var matched = Set<String>()
        for row in local {
            guard let id = row.id else { continue }
            let key = row.serverKey
            let remote = key.flatMap { serverByKey[$0] }
            if let key, remote != nil { matched.insert(key) }
            switch row.state {
            case .synced:
                if var remote {
                    remote.id = id
                    remote.revision = row.revision
                    remote.createdAt = row.createdAt
                    if remote != row { plan.save.append(remote) }
                } else {
                    plan.delete.append(id)
                }
            case .pendingCreate:
                if row.kind != .highlight, var remote {
                    remote.id = id
                    remote.revision = row.revision
                    remote.createdAt = row.createdAt
                    plan.save.append(remote)
                }
            case .pendingUpdate:
                if remote == nil {
                    var again = row
                    again.serverId = nil
                    again.state = .pendingCreate
                    plan.save.append(again)
                    plan.recreated.append(id)
                }
            case .pendingDelete:
                if remote == nil { plan.delete.append(id) }
            }
        }
        for mark in server {
            guard let key = mark.serverKey, !matched.contains(key) else { continue }
            var added = mark
            added.id = nil
            added.state = .synced
            plan.save.append(added)
        }
        return plan
    }
}
