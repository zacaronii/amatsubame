import Foundation
import GRDB

public enum OutboxJobKind: String, Codable, CaseIterable, Sendable, DatabaseValueConvertible {
    case ankiNote, kavitaProgress, jellyfinProgress, jellyfinSubtitle, audiobookshelfProgress
    /// An item marked watched or unwatched by hand (`JellyfinPlayedPayload`).
    case jellyfinPlayed
    /// A listening session for Audiobookshelf's stats (`AudiobookshelfSessionPayload`).
    case audiobookshelfSession
    /// Lookups to count on a linked Hachidori host (`HostLookupCountJob`).
    case hachidoriLookupCount
    /// A word marked known or ignored (or cleared) to tell the Hachidori host (`WordStatusJob`).
    case hachidoriWordStatus
    /// A Yomu bookmark or highlight to bring up to date on Kavita (`ReaderMarkJob`).
    case kavitaReaderMark
    /// A series added to or removed from Kavita's Want to Read (`WantToReadJob`).
    case kavitaWantToRead
    /// A Kavita collection made or deleted, or a series added to or taken out of one (`CollectionJob`).
    case kavitaCollection
    /// A Kavita reading list made or deleted, an item added or taken out, or a move (`ReadingListJob`).
    case kavitaReadingList
}

public enum OutboxJobState: String, Codable, Sendable, DatabaseValueConvertible {
    /// Waiting to be sent (possibly backing off until `nextAttemptAt`).
    case pending
    /// Claimed by the worker; reset to pending on launch in case the app died mid-send.
    case inFlight
    case sent
    /// Needs user action (retry or edit). Never deleted automatically.
    case failed
}

public struct OutboxJob: Codable, Equatable, Identifiable, Sendable, FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var kind: OutboxJobKind
    public var coalesceKey: String?
    public var payload: Data
    public var state: OutboxJobState
    public var attempts: Int
    public var lastError: String?
    /// Set while the job waits for another one (`OutboxWait`): not a failure, and no attempt.
    public var waitingFor: String?
    public var nextAttemptAt: Date
    public var createdAt: Date
    public var updatedAt: Date

    public static let media = hasMany(OutboxMedia.self, using: OutboxMedia.jobForeignKey)

    public init(
        id: Int64? = nil, kind: OutboxJobKind, coalesceKey: String? = nil, payload: Data, state: OutboxJobState,
        attempts: Int = 0, lastError: String? = nil, waitingFor: String? = nil, nextAttemptAt: Date, createdAt: Date, updatedAt: Date
    ) {
        self.id = id
        self.kind = kind
        self.coalesceKey = coalesceKey
        self.payload = payload
        self.state = state
        self.attempts = attempts
        self.lastError = lastError
        self.waitingFor = waitingFor
        self.nextAttemptAt = nextAttemptAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public func decodePayload<P: Decodable>(_ type: P.Type) throws -> P {
        try JSONDecoder().decode(P.self, from: payload)
    }
}

public struct OutboxMedia: Codable, Equatable, Identifiable, Sendable, FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var jobId: Int64
    /// The Anki media slot, e.g. `picture` or `audio`.
    public var field: String
    /// Path relative to the outbox media directory.
    public var filename: String

    static let jobForeignKey = ForeignKey(["jobId"])

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

public struct OutboxMediaInput: Sendable, Equatable {
    public var field: String
    public var filename: String
    public init(field: String, filename: String) {
        self.field = field
        self.filename = filename
    }
}

public struct ClaimedJob: Sendable, Equatable {
    public var job: OutboxJob
    public var media: [OutboxMedia]
}

public struct OutboxSummary: Equatable, Sendable {
    public var pending: Int
    public var failed: Int
    public init(pending: Int, failed: Int) {
        self.pending = pending
        self.failed = failed
    }
    public static let empty = OutboxSummary(pending: 0, failed: 0)
}

public enum OutboxError: Error, Equatable {
    /// Coalesced jobs replace each other, which would orphan media files.
    case mediaNotAllowedForCoalescedJobs
    case jobNotFound
}

/// Database operations for the outbox. Every network write in the app is
/// enqueued here and delivered later by `OutboxWorker`.
public struct OutboxStore: Sendable {
    public static let maxBackoff: TimeInterval = 6 * 60 * 60
    public static let sentProgressRetention: TimeInterval = 7 * 24 * 60 * 60

    public let database: AppDatabase
    public let now: @Sendable () -> Date

    public init(database: AppDatabase, now: @escaping @Sendable () -> Date = Date.init) {
        self.database = database
        self.now = now
    }

    /// The shortest wait `markWaiting` schedules.
    public static let minimumWait: TimeInterval = 1

    /// Delay before the next attempt after `attempts` failures: 30s, 60s, 120s… capped at 6h.
    public static func backoff(afterAttempts attempts: Int) -> TimeInterval {
        let exponent = Double(max(attempts - 1, 0))
        return min(30 * pow(2, exponent), maxBackoff)
    }

    @discardableResult
    public func enqueue(
        _ payload: some Encodable,
        kind: OutboxJobKind,
        coalesceKey: String? = nil,
        media: [OutboxMediaInput] = [],
        notBefore: Date? = nil
    ) throws -> Int64 {
        try enqueue(kind: kind, payload: JSONEncoder().encode(payload), coalesceKey: coalesceKey, media: media, notBefore: notBefore)
    }

    /// Adds a job. If `coalesceKey` matches a job that is still pending, that job
    /// takes the new payload instead (newest progress wins). A job already in
    /// flight is left alone and a new pending job is added behind it.
    /// `notBefore` holds the job back (e.g. a few seconds so a mined card can be undone).
    @discardableResult
    public func enqueue(
        kind: OutboxJobKind,
        payload: Data,
        coalesceKey: String? = nil,
        media: [OutboxMediaInput] = [],
        notBefore: Date? = nil
    ) throws -> Int64 {
        if coalesceKey != nil && !media.isEmpty {
            throw OutboxError.mediaNotAllowedForCoalescedJobs
        }
        let now = now()
        return try database.writer.write { db in
            try Self.insert(db, kind: kind, payload: payload, coalesceKey: coalesceKey, media: media, notBefore: notBefore, now: now)
        }
    }

    /// Adds a job inside a write already open on this outbox's database, so a row and the job
    /// that sends it are saved together (a refresh can never see one without the other).
    @discardableResult
    public func enqueue(_ payload: some Encodable, kind: OutboxJobKind, coalesceKey: String, in db: Database) throws -> Int64 {
        try Self.insert(db, kind: kind, payload: JSONEncoder().encode(payload), coalesceKey: coalesceKey, media: [], notBefore: nil, now: now())
    }

    private static func insert(_ db: Database, kind: OutboxJobKind, payload: Data, coalesceKey: String?, media: [OutboxMediaInput],
                               notBefore: Date?, now: Date) throws -> Int64 {
        if let coalesceKey,
           var existing = try OutboxJob
               .filter(Column("coalesceKey") == coalesceKey && Column("state") == OutboxJobState.pending)
               .fetchOne(db) {
            existing.payload = payload
            existing.attempts = 0
            existing.lastError = nil
            existing.waitingFor = nil
            existing.nextAttemptAt = now
            existing.updatedAt = now
            try existing.update(db)
            return existing.id!
        }
        var job = OutboxJob(
            kind: kind, coalesceKey: coalesceKey, payload: payload, state: .pending,
            attempts: 0, lastError: nil, nextAttemptAt: max(notBefore ?? now, now), createdAt: now, updatedAt: now
        )
        try job.insert(db)
        for item in media {
            var row = OutboxMedia(jobId: job.id!, field: item.field, filename: item.filename)
            try row.insert(db)
        }
        return job.id!
    }

    /// Atomically marks due pending jobs of the given kinds as in flight and returns them, oldest first.
    public func claimDueJobs(kinds: Set<OutboxJobKind>, limit: Int = 20) throws -> [ClaimedJob] {
        guard !kinds.isEmpty else { return [] }
        let now = now()
        return try database.writer.write { db in
            let jobs = try OutboxJob
                .filter(Column("state") == OutboxJobState.pending)
                .filter(Column("nextAttemptAt") <= now)
                .filter(kinds.map(\.rawValue).contains(Column("kind")))
                .order(Column("createdAt"), Column("id"))
                .limit(limit)
                .fetchAll(db)
            return try jobs.map { job in
                var claimed = job
                claimed.state = .inFlight
                claimed.updatedAt = now
                try claimed.update(db)
                let media = try OutboxMedia.filter(Column("jobId") == job.id!).order(Column("id")).fetchAll(db)
                return ClaimedJob(job: claimed, media: media)
            }
        }
    }

    /// When the earliest backing-off job of these kinds becomes due.
    public func nextAttemptDate(kinds: Set<OutboxJobKind>) throws -> Date? {
        guard !kinds.isEmpty else { return nil }
        return try database.reader.read { db in
            try Date.fetchOne(db, OutboxJob
                .select(min(Column("nextAttemptAt")))
                .filter(Column("state") == OutboxJobState.pending)
                .filter(kinds.map(\.rawValue).contains(Column("kind"))))
        }
    }

    /// Marks a job sent and removes its media rows. Returns the media filenames
    /// so the caller can delete the files.
    @discardableResult
    public func markSent(_ id: Int64) throws -> [String] {
        let now = now()
        return try database.writer.write { db in
            guard var job = try OutboxJob.fetchOne(db, key: id) else { throw OutboxError.jobNotFound }
            job.state = .sent
            job.lastError = nil
            job.waitingFor = nil
            job.updatedAt = now
            try job.update(db)
            let media = try OutboxMedia.filter(Column("jobId") == id).fetchAll(db)
            _ = try OutboxMedia.filter(Column("jobId") == id).deleteAll(db)
            return media.map(\.filename)
        }
    }

    /// Records a transient failure and schedules the next attempt with backoff.
    public func markRetry(_ id: Int64, error: String) throws {
        let now = now()
        try database.writer.write { db in
            guard var job = try OutboxJob.fetchOne(db, key: id) else { throw OutboxError.jobNotFound }
            job.attempts += 1
            job.lastError = error
            job.waitingFor = nil
            job.updatedAt = now
            job.nextAttemptAt = now.addingTimeInterval(Self.backoff(afterAttempts: job.attempts))
            try returnToPending(&job, db)
        }
    }

    /// The job waits for another one to go first (`OutboxWait`): looked at again after `delay`
    /// (at least `minimumWait`, so a lane never claims it again at once and spins), with no
    /// attempt counted, so a long wait never grows its back-off and never reads as a failure.
    public func markWaiting(_ id: Int64, for reason: String, after delay: TimeInterval) throws {
        let delay = max(delay, Self.minimumWait)
        let now = now()
        try database.writer.write { db in
            guard var job = try OutboxJob.fetchOne(db, key: id) else { throw OutboxError.jobNotFound }
            job.waitingFor = reason
            job.updatedAt = now
            job.nextAttemptAt = now.addingTimeInterval(delay)
            try returnToPending(&job, db)
        }
    }

    /// Records a failure that needs the user (bad field mapping, rejected note…).
    public func markFailed(_ id: Int64, error: String) throws {
        let now = now()
        try database.writer.write { db in
            guard var job = try OutboxJob.fetchOne(db, key: id) else { throw OutboxError.jobNotFound }
            job.attempts += 1
            job.lastError = error
            job.waitingFor = nil
            job.state = .failed
            job.updatedAt = now
            try job.update(db)
        }
    }

    /// User-initiated retry of a failed (or backing-off) job: due immediately.
    public func retryNow(_ id: Int64) throws {
        let now = now()
        try database.writer.write { db in
            guard var job = try OutboxJob.fetchOne(db, key: id) else { throw OutboxError.jobNotFound }
            guard job.state == .failed || job.state == .pending else { return }
            job.nextAttemptAt = now
            job.updatedAt = now
            try returnToPending(&job, db)
        }
    }

    /// Deletes a job that hasn't been sent (Undo, or deleting a card in the queue).
    /// Returns its media filenames so the caller can delete the files; nil if the job
    /// is already in flight or sent.
    public func cancel(_ id: Int64) throws -> [String]? {
        try database.writer.write { db in
            guard let job = try OutboxJob.fetchOne(db, key: id) else { throw OutboxError.jobNotFound }
            guard job.state == .pending || job.state == .failed else { return nil }
            let media = try OutboxMedia.filter(Column("jobId") == id).fetchAll(db)
            try job.delete(db)
            return media.map(\.filename)
        }
    }

    /// Replaces an unsent job's payload (editing a queued card). Returns false if it's in flight or sent.
    @discardableResult
    public func updatePayload(_ id: Int64, payload: Data) throws -> Bool {
        let now = now()
        return try database.writer.write { db in
            guard var job = try OutboxJob.fetchOne(db, key: id) else { throw OutboxError.jobNotFound }
            guard job.state == .pending || job.state == .failed else { return false }
            job.payload = payload
            job.updatedAt = now
            try job.update(db)
            return true
        }
    }

    /// Records how far a job in flight got (a count sent one lookup at a time), so a retry
    /// sends only the rest.
    public func saveProgress(_ id: Int64, payload: Data) throws {
        let now = now()
        try database.writer.write { db in
            guard var job = try OutboxJob.fetchOne(db, key: id) else { throw OutboxError.jobNotFound }
            job.payload = payload
            job.updatedAt = now
            try job.update(db)
        }
    }

    public func job(_ id: Int64) throws -> ClaimedJob? {
        try database.reader.read { db in
            guard let job = try OutboxJob.fetchOne(db, key: id) else { return nil }
            return ClaimedJob(job: job, media: try OutboxMedia.filter(Column("jobId") == id).order(Column("id")).fetchAll(db))
        }
    }

    /// Makes every backing-off job due now (the user tapped Sync Now, or the network came back).
    /// Jobs still inside a `notBefore` hold (a card's undo window) aren't touched.
    @discardableResult
    public func retryWaitingNow() throws -> Int {
        let now = now()
        return try database.writer.write { db in
            try OutboxJob
                .filter(Column("state") == OutboxJobState.pending)
                .filter(Column("attempts") > 0)
                .filter(Column("nextAttemptAt") > now)
                .updateAll(db, Column("nextAttemptAt").set(to: now))
        }
    }

    /// Crash recovery: anything left in flight from a previous run goes back to pending.
    @discardableResult
    public func resetInFlight() throws -> Int {
        try database.writer.write { db in
            var count = 0
            for var job in try OutboxJob.filter(Column("state") == OutboxJobState.inFlight).fetchAll(db) {
                try returnToPending(&job, db)
                count += 1
            }
            return count
        }
    }

    /// The coalesce keys of reading progress changes not sent yet: waiting, backing off, held or
    /// being sent (one that failed for good no longer counts).
    public static func unsentProgressKeys(_ db: Database) throws -> Set<String> {
        Set(try String?.fetchAll(db, OutboxJob.select(Column("coalesceKey"))
            .filter(Column("kind") == OutboxJobKind.kavitaProgress
                    && [OutboxJobState.pending.rawValue, OutboxJobState.inFlight.rawValue].contains(Column("state"))))
            .compactMap(\.self))
    }

    public func unsentProgressKeys() throws -> Set<String> {
        try database.reader.read { try Self.unsentProgressKeys($0) }
    }

    /// Whether this chapter has a progress change not sent yet (`LocalReadingProgress.progressKeys`).
    public func hasUnsentProgress(chapterId: Int, seriesId: Int) throws -> Bool {
        let keys = try unsentProgressKeys()
        return LocalReadingProgress.progressKeys(chapterId: chapterId, seriesId: seriesId).contains(where: keys.contains)
    }

    /// The last job with one of these coalesce keys that was sent (kept `sentProgressRetention`),
    /// leaving out `job` itself.
    public func lastSent(coalesceKeys: [String], kind: OutboxJobKind, excluding job: Int64?) throws -> OutboxJob? {
        try database.reader.read { db in
            try OutboxJob.filter(Column("kind") == kind && coalesceKeys.contains(Column("coalesceKey")) && Column("state") == OutboxJobState.sent)
                .filter(Column("id") != (job ?? -1))
                .order(Column("updatedAt").desc, Column("id").desc).fetchOne(db)
        }
    }

    /// Deletes sent progress jobs older than the retention window. Sent cards are kept as history.
    @discardableResult
    public func pruneSentProgress() throws -> Int {
        let cutoff = now().addingTimeInterval(-Self.sentProgressRetention)
        return try database.writer.write { db in
            try OutboxJob
                .filter(Column("state") == OutboxJobState.sent)
                .filter(Column("kind") != OutboxJobKind.ankiNote)
                .filter(Column("updatedAt") < cutoff)
                .deleteAll(db)
        }
    }

    public func jobs(states: Set<OutboxJobState>) throws -> [OutboxJob] {
        try database.reader.read { db in
            try OutboxJob
                .filter(states.map(\.rawValue).contains(Column("state")))
                .order(Column("createdAt").desc, Column("id").desc)
                .fetchAll(db)
        }
    }

    /// What's waiting to send (pending, in flight or failed), by kind: Settings' status card
    /// and Advanced ▸ Waiting to Sync.
    public func waitingCounts() throws -> [OutboxJobKind: Int] {
        try database.reader.read(Self.fetchWaitingCounts)
    }

    public func observeWaitingCounts() -> AsyncThrowingStream<[OutboxJobKind: Int], any Error> {
        database.values(Self.fetchWaitingCounts)
    }

    @Sendable private static func fetchWaitingCounts(_ db: Database) throws -> [OutboxJobKind: Int] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT kind, COUNT(*) AS count FROM outboxJob WHERE state IN (?, ?, ?) GROUP BY kind
            """, arguments: [OutboxJobState.pending.rawValue, OutboxJobState.inFlight.rawValue, OutboxJobState.failed.rawValue])
        var counts: [OutboxJobKind: Int] = [:]
        for row in rows {
            if let kind = OutboxJobKind(rawValue: row["kind"]) { counts[kind] = row["count"] }
        }
        return counts
    }

    /// The coalesce keys of a kind's jobs still to be sent (waiting, sending or failed and listed).
    static func queuedKeys(_ db: Database, kind: OutboxJobKind) throws -> Set<String> {
        let keys = try String?.fetchAll(db, OutboxJob
            .select(Column("coalesceKey"))
            .filter(Column("kind") == kind)
            .filter([OutboxJobState.pending.rawValue, OutboxJobState.inFlight.rawValue, OutboxJobState.failed.rawValue].contains(Column("state"))))
        return Set(keys.compactMap(\.self))
    }

    /// The coalesce keys of a kind's jobs still to be sent: waiting or being sent (not failed).
    static func sendingKeys(_ db: Database, kind: OutboxJobKind) throws -> Set<String> {
        Set(try String?.fetchAll(db, OutboxJob.select(Column("coalesceKey"))
            .filter(Column("kind") == kind && [OutboxJobState.pending.rawValue, OutboxJobState.inFlight.rawValue].contains(Column("state"))))
            .compactMap(\.self))
    }

    /// The coalesce keys of a kind's jobs waiting (not yet being sent).
    static func pendingKeys(_ db: Database, kind: OutboxJobKind) throws -> Set<String> {
        Set(try String?.fetchAll(db, OutboxJob.select(Column("coalesceKey"))
            .filter(Column("kind") == kind && Column("state") == OutboxJobState.pending)).compactMap(\.self))
    }

    /// Deletes the unsent jobs with these coalesce keys, inside a write (a jobs' row removed with
    /// them). One being sent is left to finish; it finds its row gone.
    public static func cancel(_ db: Database, coalesceKeys keys: [String]) throws {
        guard !keys.isEmpty else { return }
        try OutboxJob
            .filter(keys.contains(Column("coalesceKey")))
            .filter([OutboxJobState.pending.rawValue, OutboxJobState.failed.rawValue].contains(Column("state")))
            .deleteAll(db)
    }

    /// Deletes every unsent job of a progress kind (Advanced ▸ Waiting to Sync ▸ Clear).
    /// Cards go through `MiningService.cancel`, which also removes their media.
    @discardableResult
    public func cancelAll(kind: OutboxJobKind) throws -> Int {
        precondition(kind != .ankiNote, "cards are cancelled one by one with their media")
        return try database.writer.write { db in
            try OutboxJob
                .filter(Column("kind") == kind)
                .filter([OutboxJobState.pending.rawValue, OutboxJobState.failed.rawValue].contains(Column("state")))
                .deleteAll(db)
        }
    }

    public func summary() throws -> OutboxSummary {
        try database.reader.read(Self.fetchSummary)
    }

    public func observeSummary() -> AsyncThrowingStream<OutboxSummary, any Error> {
        database.values(Self.fetchSummary)
    }

    public func observeJobs(states: Set<OutboxJobState>) -> AsyncThrowingStream<[OutboxJob], any Error> {
        database.values { db in
            try OutboxJob
                .filter(states.map(\.rawValue).contains(Column("state")))
                .order(Column("createdAt").desc, Column("id").desc)
                .fetchAll(db)
        }
    }

    @Sendable private static func fetchSummary(_ db: Database) throws -> OutboxSummary {
        OutboxSummary(
            pending: try OutboxJob
                .filter([OutboxJobState.pending.rawValue, OutboxJobState.inFlight.rawValue].contains(Column("state")))
                .fetchCount(db),
            failed: try OutboxJob.filter(Column("state") == OutboxJobState.failed).fetchCount(db)
        )
    }

    /// Moves a job back to pending. If another pending job already holds its
    /// coalesce key (newer progress enqueued meanwhile), the newer one wins and
    /// this one is dropped. Jobs without a key (cards) are never dropped.
    private func returnToPending(_ job: inout OutboxJob, _ db: Database) throws {
        if let key = job.coalesceKey,
           try OutboxJob
               .filter(Column("coalesceKey") == key && Column("state") == OutboxJobState.pending)
               .filter(Column("id") != job.id!)
               .fetchCount(db) > 0 {
            try job.delete(db)
            return
        }
        job.state = .pending
        try job.update(db)
    }
}
