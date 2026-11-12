import Core
import Foundation
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
