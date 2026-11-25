import Core
import Foundation
import Synchronization
import Testing

struct RecordingHandler: OutboxHandler {
    let kind: OutboxJobKind
    let result: @Sendable (OutboxJob) throws -> Void

    func send(_ job: OutboxJob, media: [(field: String, url: URL)]) async throws {
        try result(job)
    }
}

/// Waits on `release` before sending the job `slowId`, like a server that doesn't answer.
struct HangingHandler: OutboxHandler {
    let kind: OutboxJobKind
    let slowId: Int64
    let release: AsyncStream<Void>

    func send(_ job: OutboxJob, media: [(field: String, url: URL)]) async throws {
        if job.id == slowId { for await _ in release { break } }
    }
}

@Suite struct OutboxWorkerTests {
    let store: OutboxStore
    let media: OutboxMediaStorage

    init() throws {
        store = OutboxStore(database: try AppDatabase.inMemory())
        media = OutboxMediaStorage(directory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
    }

    @Test func sendsDueJobsAndDeletesMediaFiles() async throws {
        let filename = try media.store(Data("img".utf8), fileExtension: "webp")
        try store.enqueue(Card(expression: "a"), kind: .ankiNote, media: [OutboxMediaInput(field: "picture", filename: filename)])
        let handler = RecordingHandler(kind: .ankiNote) { _ in }
        let worker = OutboxWorker(store: store, mediaStorage: media, handlers: [handler])

        let report = await worker.drain()
        #expect(report == OutboxDrainReport(sent: 1, retried: 0, failed: 0))
        #expect(!FileManager.default.fileExists(atPath: media.url(for: filename).path()))
        #expect(try store.summary() == .empty)
    }

    /// A demo server's kinds are held: their jobs stay queued and unsent (so the device's place
    /// keeps winning) while other servers' jobs go as usual. Letting go discards them: they
    /// name the demo server's items and are never sent, to it or to another server.
    @Test func heldKindsStayQueuedAndAreDiscardedOnRelease() async throws {
        let sent = Mutex<[OutboxJobKind]>([])
        let worker = OutboxWorker(store: store, mediaStorage: media, handlers: [
            RecordingHandler(kind: .kavitaProgress) { _ in sent.withLock { $0.append(.kavitaProgress) } },
            RecordingHandler(kind: .kavitaReadingList) { _ in sent.withLock { $0.append(.kavitaReadingList) } },
            RecordingHandler(kind: .ankiNote) { _ in sent.withLock { $0.append(.ankiNote) } },
        ])
        try store.setHeld([.kavitaProgress, .kavitaReadingList])
        let progress = try store.enqueue(Progress(chapterId: 1, page: 3), kind: .kavitaProgress, coalesceKey: "c1")
        try store.enqueue(Progress(chapterId: 2, page: 1), kind: .kavitaReadingList, coalesceKey: "l1")
        try store.enqueue(Card(expression: "a"), kind: .ankiNote)
        #expect(await worker.drain().sent == 1)
        #expect(sent.withLock { $0 } == [.ankiNote])
        #expect(try store.jobs(states: [.pending]).map(\.kind).sorted { $0.rawValue < $1.rawValue } == [.kavitaProgress, .kavitaReadingList])
        #expect(try store.jobs(states: [.pending]).contains { $0.id == progress })

        #expect(try store.setHeld([]) == 2, "both held jobs discarded")
        #expect(await worker.drain().sent == 0)
        #expect(sent.withLock { $0 } == [.ankiNote], "nothing held was ever sent")
        #expect(try store.jobs(states: [.pending, .failed, .inFlight]).isEmpty)
        #expect(try store.heldKinds().isEmpty)
    }

    /// The hold is kept in the database: a new launch holds from the start, before the
    /// accounts are read.
    @Test func theHoldOutlastsALaunch() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "held-\(UUID().uuidString)")
        try OutboxStore(database: try AppDatabase.onDisk(directory: dir)).setHeld([.jellyfinProgress])
        let store = OutboxStore(database: try AppDatabase.onDisk(directory: dir))
        #expect(try store.heldKinds() == [.jellyfinProgress])
        try store.enqueue(Progress(chapterId: 1, page: 1), kind: .jellyfinProgress, coalesceKey: "e1")
        let worker = OutboxWorker(store: store, mediaStorage: media, handlers: [RecordingHandler(kind: .jellyfinProgress) { _ in }])
        #expect(await worker.drain().sent == 0)
    }

    /// Every kind names the server it writes to, so a demo server's are all held.
    @Test func eachKindNamesItsServer() {
        #expect(OutboxJobKind.allCases.filter { $0.server == .kavita }.count == 5)
        #expect(OutboxJobKind.kavitaProgress.server == .kavita && OutboxJobKind.jellyfinPlayed.server == .jellyfin)
        #expect(OutboxJobKind.audiobookshelfUpNext.server == .audiobookshelf && OutboxJobKind.ankiNote.server == .anki)
        #expect(OutboxJobKind.hachidoriWordStatus.server == nil)
    }

    @Test func transientErrorsRetryAndPermanentErrorsFail() async throws {
        let retryId = try store.enqueue(Card(expression: "retry"), kind: .ankiNote)
        let failId = try store.enqueue(Card(expression: "fail"), kind: .ankiNote)
        let handler = RecordingHandler(kind: .ankiNote) { job in
            if job.id == retryId { throw ConnectionError.unreachable("offline") }
            throw OutboxPermanentFailure("duplicate")
        }
        let worker = OutboxWorker(store: store, mediaStorage: media, handlers: [handler])

        let report = await worker.drain()
        #expect(report == OutboxDrainReport(sent: 0, retried: 1, failed: 1))
        let jobs = try store.jobs(states: [.pending, .failed])
        #expect(jobs.first { $0.id == retryId }?.state == .pending)
        #expect(jobs.first { $0.id == failId }?.state == .failed)
        #expect(jobs.first { $0.id == failId }?.lastError == "duplicate")
    }

    /// A job waiting for another one: looked at again in 30 s each time, no attempt counted
    /// (its back-off never grows), shown as waiting rather than as an error; a real failure
    /// afterwards counts and clears the wait.
    @Test func aWaitDoesNotCountAnAttempt() async throws {
        let clock = TestClock()
        let store = OutboxStore(database: try AppDatabase.inMemory()) { clock.now }
        let id = try store.enqueue(Progress(chapterId: 1, page: 1), kind: .kavitaReadingList, coalesceKey: "w")
        let fails = Mutex(false)
        let handler = RecordingHandler(kind: .kavitaReadingList) { _ in
            if fails.withLock({ $0 }) { throw ConnectionError.unreachable("offline") }
            throw OutboxWait("Waiting for an earlier change.")
        }
        let worker = OutboxWorker(store: store, mediaStorage: media, handlers: [handler])
        for round in 1...5 {
            let report = await worker.drain()
            #expect(report == OutboxDrainReport(waiting: 1), "round \(round)")
            let job = try #require(try store.jobs(states: [.pending]).first { $0.id == id })
            #expect(job.attempts == 0)
            #expect(job.lastError == nil)
            #expect(job.waitingFor == "Waiting for an earlier change.")
            #expect(job.nextAttemptAt == clock.now.addingTimeInterval(30))
            clock.advance(30)
        }
        fails.withLock { $0 = true }
        #expect(await worker.drain() == OutboxDrainReport(retried: 1))
        let job = try #require(try store.jobs(states: [.pending]).first { $0.id == id })
        #expect(job.attempts == 1 && job.waitingFor == nil && job.lastError != nil)
        #expect(try store.summary() == OutboxSummary(pending: 1, failed: 0), "a wait is never counted as failed")
    }

    /// A wait of 0 (or less) would be claimed again at once and spin its lane: it's held to
    /// `minimumWait`.
    @Test func aWaitIsNeverShorterThanTheMinimum() async throws {
        let clock = TestClock()
        let store = OutboxStore(database: try AppDatabase.inMemory()) { clock.now }
        let id = try store.enqueue(Progress(chapterId: 1, page: 1), kind: .kavitaReadingList, coalesceKey: "w")
        let calls = Mutex(0)
        let handler = RecordingHandler(kind: .kavitaReadingList) { _ in
            calls.withLock { $0 += 1 }
            throw OutboxWait("now", retryAfter: 0)
        }
        let worker = OutboxWorker(store: store, mediaStorage: media, handlers: [handler])
        #expect(await worker.drain() == OutboxDrainReport(waiting: 1))
        #expect(calls.withLock { $0 } == 1, "not claimed again in the same drain")
        let job = try #require(try store.jobs(states: [.pending]).first { $0.id == id })
        #expect(job.nextAttemptAt == clock.now.addingTimeInterval(OutboxStore.minimumWait))
    }

    @Test func kindsWithoutHandlerStayPending() async throws {
        try store.enqueue(Progress(chapterId: 1, page: 1), kind: .jellyfinProgress, coalesceKey: "j")
        let worker = OutboxWorker(store: store, mediaStorage: media)
        #expect(await worker.drain() == OutboxDrainReport())
        #expect(try store.jobs(states: [.pending]).count == 1)
    }

    /// A server that hangs holds up only its own jobs, and the job after it isn't marked
    /// as sending while it waits.
    @Test func eachKindSendsOnItsOwnAndClaimsOneJobAtATime() async throws {
        let slow = try store.enqueue(Progress(chapterId: 1, page: 1), kind: .audiobookshelfProgress, coalesceKey: "a")
        let waiting = try store.enqueue(Progress(chapterId: 2, page: 1), kind: .audiobookshelfProgress, coalesceKey: "b")
        try store.enqueue(Card(expression: "a"), kind: .ankiNote)
        let gate = AsyncStream<Void>.makeStream()
        let store = store
        let hanging = HangingHandler(kind: .audiobookshelfProgress, slowId: slow, release: gate.stream)
        let worker = OutboxWorker(store: store, mediaStorage: media, handlers: [hanging, RecordingHandler(kind: .ankiNote) { _ in }])

        let drain = Task { await worker.drain() }
        for _ in 0..<200 where try store.jobs(states: [.pending, .inFlight]).contains(where: { $0.kind == .ankiNote }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        let jobs = try store.jobs(states: [.pending, .inFlight])
        #expect(!jobs.contains { $0.kind == .ankiNote })
        #expect(jobs.first { $0.id == slow }?.state == .inFlight)
        #expect(jobs.first { $0.id == waiting }?.state == .pending)
        gate.continuation.yield()
        #expect(await drain.value.sent == 3)
    }

    @Test func recoverResetsInFlight() async throws {
        try store.enqueue(Card(expression: "a"), kind: .ankiNote)
        _ = try store.claimDueJobs(kinds: [.ankiNote])
        let handler = RecordingHandler(kind: .ankiNote) { _ in }
        let worker = OutboxWorker(store: store, mediaStorage: media, handlers: [handler])

        #expect(await worker.drain().sent == 0)
        try await worker.recover()
        #expect(await worker.drain().sent == 1)
    }
}

@Suite struct OutboxRetrySchedulingTests {
    @Test func failedSendSchedulesItsOwnRetry() async throws {
        let store = OutboxStore(database: try AppDatabase.inMemory())
        let media = OutboxMediaStorage(directory: FileManager.default.temporaryDirectory)
        let handler = RecordingHandler(kind: .ankiNote) { _ in throw ConnectionError.unreachable("offline") }
        let worker = OutboxWorker(store: store, mediaStorage: media, handlers: [handler])
        try store.enqueue(Card(expression: "a"), kind: .ankiNote)

        let before = Date()
        await worker.drain()
        let retry = try #require(await worker.scheduledRetry)
        #expect(abs(retry.timeIntervalSince(before) - OutboxStore.backoff(afterAttempts: 1)) < 5)
        #expect(try store.nextAttemptDate(kinds: [.ankiNote]) == retry)
        #expect(try store.nextAttemptDate(kinds: [.kavitaProgress]) == nil)
    }

    @Test func nothingPendingMeansNoRetry() async throws {
        let store = OutboxStore(database: try AppDatabase.inMemory())
        let worker = OutboxWorker(store: store, mediaStorage: OutboxMediaStorage(directory: FileManager.default.temporaryDirectory),
                                  handlers: [RecordingHandler(kind: .ankiNote) { _ in }])
        try store.enqueue(Card(expression: "a"), kind: .ankiNote)
        await worker.drain()
        #expect(await worker.scheduledRetry == nil)
    }
}
