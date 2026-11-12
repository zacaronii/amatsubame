import Core
import Foundation
import GRDB
import Synchronization
import Testing

/// A controllable clock for backoff and retention tests.
final class TestClock: Sendable {
    private let current = Mutex(Date(timeIntervalSince1970: 1_800_000_000))
    var now: Date { current.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { current.withLock { $0 += seconds } }
}

struct Progress: Codable, Equatable {
    var chapterId: Int
    var page: Int
}

struct Card: Codable, Equatable {
    var expression: String
}

@Suite struct OutboxStoreTests {
    let clock = TestClock()
    let store: OutboxStore

    init() throws {
        let clock = clock
        store = OutboxStore(database: try AppDatabase.inMemory(), now: { clock.now })
    }

    @Test func waitingIsCountedAndClearedByKind() throws {
        _ = try store.enqueue(Card(expression: "食べる"), kind: .ankiNote)
        _ = try store.enqueue(Card(expression: "飲む"), kind: .ankiNote)
        _ = try store.enqueue(Progress(chapterId: 1, page: 2), kind: .kavitaProgress, coalesceKey: "kavita.chapter.1")
        _ = try store.enqueue(Progress(chapterId: 2, page: 5), kind: .kavitaProgress, coalesceKey: "kavita.chapter.2")
        #expect(try store.waitingCounts() == [.ankiNote: 2, .kavitaProgress: 2])
        #expect(try store.cancelAll(kind: .kavitaProgress) == 2)
        #expect(try store.waitingCounts() == [.ankiNote: 2])
    }

    @Test func enqueuedJobIsPendingAndDue() throws {
        let id = try store.enqueue(Card(expression: "食べる"), kind: .ankiNote)
        let claimed = try store.claimDueJobs(kinds: [.ankiNote])
        #expect(claimed.map(\.job.id) == [id])
        #expect(claimed[0].job.state == .inFlight)
        #expect(try claimed[0].job.decodePayload(Card.self) == Card(expression: "食べる"))
    }

    @Test func progressForSameKeyCollapsesToNewest() throws {
        let first = try store.enqueue(Progress(chapterId: 1, page: 3), kind: .kavitaProgress, coalesceKey: "kavita.chapter.1")
        let second = try store.enqueue(Progress(chapterId: 1, page: 5), kind: .kavitaProgress, coalesceKey: "kavita.chapter.1")
        try store.enqueue(Progress(chapterId: 2, page: 1), kind: .kavitaProgress, coalesceKey: "kavita.chapter.2")

        #expect(first == second)
        let pending = try store.jobs(states: [.pending])
        #expect(pending.count == 2)
        let chapter1 = try #require(pending.first { $0.coalesceKey == "kavita.chapter.1" })
        #expect(try chapter1.decodePayload(Progress.self).page == 5)
    }

    @Test func coalescingResetsBackoff() throws {
        let id = try store.enqueue(Progress(chapterId: 1, page: 3), kind: .kavitaProgress, coalesceKey: "k")
        _ = try store.claimDueJobs(kinds: [.kavitaProgress])
        try store.markRetry(id, error: "offline")
        try store.enqueue(Progress(chapterId: 1, page: 4), kind: .kavitaProgress, coalesceKey: "k")

        let job = try #require(try store.jobs(states: [.pending]).first)
        #expect(job.attempts == 0)
        #expect(job.lastError == nil)
        #expect(job.nextAttemptAt == clock.now)
    }

    @Test func newProgressWhileInFlightIsQueuedBehindIt() throws {
        let first = try store.enqueue(Progress(chapterId: 1, page: 3), kind: .kavitaProgress, coalesceKey: "k")
        _ = try store.claimDueJobs(kinds: [.kavitaProgress])
        let second = try store.enqueue(Progress(chapterId: 1, page: 9), kind: .kavitaProgress, coalesceKey: "k")
        #expect(first != second)

        // The in-flight send fails: the stale job is dropped, the newer one survives.
        try store.markRetry(first, error: "offline")
        let remaining = try store.jobs(states: [.pending, .inFlight, .failed])
        #expect(remaining.map(\.id) == [second])
        #expect(try remaining[0].decodePayload(Progress.self).page == 9)
    }

    @Test func cardsAreNeverCollapsed() throws {
        try store.enqueue(Card(expression: "食べる"), kind: .ankiNote)
        try store.enqueue(Card(expression: "食べる"), kind: .ankiNote)
        #expect(try store.jobs(states: [.pending]).count == 2)
    }

    @Test func coalescedJobsCannotCarryMedia() {
        #expect(throws: OutboxError.mediaNotAllowedForCoalescedJobs) {
            try store.enqueue(
                Progress(chapterId: 1, page: 1), kind: .kavitaProgress, coalesceKey: "k",
                media: [OutboxMediaInput(field: "picture", filename: "a.jpg")]
            )
        }
    }

    @Test func retryBacksOffExponentiallyWithCap() throws {
        #expect(OutboxStore.backoff(afterAttempts: 1) == 30)
        #expect(OutboxStore.backoff(afterAttempts: 2) == 60)
        #expect(OutboxStore.backoff(afterAttempts: 5) == 480)
        #expect(OutboxStore.backoff(afterAttempts: 40) == OutboxStore.maxBackoff)

        let id = try store.enqueue(Card(expression: "a"), kind: .ankiNote)
        _ = try store.claimDueJobs(kinds: [.ankiNote])
        try store.markRetry(id, error: "offline")

        #expect(try store.claimDueJobs(kinds: [.ankiNote]).isEmpty)
        clock.advance(29)
        #expect(try store.claimDueJobs(kinds: [.ankiNote]).isEmpty)
        clock.advance(1)
        let claimed = try store.claimDueJobs(kinds: [.ankiNote])
        #expect(claimed.first?.job.attempts == 1)
        #expect(claimed.first?.job.lastError == "offline")
    }

    @Test func failedCardsStayUntilRetriedByUser() throws {
        let id = try store.enqueue(Card(expression: "a"), kind: .ankiNote)
        _ = try store.claimDueJobs(kinds: [.ankiNote])
        try store.markFailed(id, error: "cannot create note because it is empty")

        clock.advance(365 * 24 * 3600)
        try store.pruneSentProgress()
        #expect(try store.claimDueJobs(kinds: [.ankiNote]).isEmpty)
        #expect(try store.summary() == OutboxSummary(pending: 0, failed: 1))

        try store.retryNow(id)
        #expect(try store.claimDueJobs(kinds: [.ankiNote]).map(\.job.id) == [id])
    }

    @Test func inFlightJobsResetOnLaunch() throws {
        let id = try store.enqueue(Card(expression: "a"), kind: .ankiNote)
        _ = try store.claimDueJobs(kinds: [.ankiNote])
        #expect(try store.claimDueJobs(kinds: [.ankiNote]).isEmpty)

        #expect(try store.resetInFlight() == 1)
        #expect(try store.claimDueJobs(kinds: [.ankiNote]).map(\.job.id) == [id])
    }

    @Test func claimOnlyReturnsRequestedKinds() throws {
        try store.enqueue(Card(expression: "a"), kind: .ankiNote)
        try store.enqueue(Progress(chapterId: 1, page: 1), kind: .kavitaProgress, coalesceKey: "k")
        #expect(try store.claimDueJobs(kinds: []).isEmpty)
        #expect(try store.claimDueJobs(kinds: [.kavitaProgress]).map(\.job.kind) == [.kavitaProgress])
        #expect(try store.jobs(states: [.pending]).map(\.kind) == [.ankiNote])
    }

    @Test func claimReturnsOldestFirst() throws {
        let a = try store.enqueue(Card(expression: "a"), kind: .ankiNote)
        clock.advance(1)
        let b = try store.enqueue(Card(expression: "b"), kind: .ankiNote)
        #expect(try store.claimDueJobs(kinds: [.ankiNote]).map(\.job.id) == [a, b])
    }

    @Test func sentReturnsMediaFilenamesAndKeepsCardHistory() throws {
        let id = try store.enqueue(
            Card(expression: "a"), kind: .ankiNote,
            media: [OutboxMediaInput(field: "picture", filename: "p.webp"), OutboxMediaInput(field: "audio", filename: "s.mp3")]
        )
        let claimed = try store.claimDueJobs(kinds: [.ankiNote])
        #expect(claimed[0].media.map(\.field) == ["picture", "audio"])

        #expect(try store.markSent(id) == ["p.webp", "s.mp3"])
        clock.advance(30 * 24 * 3600)
        try store.pruneSentProgress()
        #expect(try store.jobs(states: [.sent]).map(\.id) == [id])
    }

    @Test func sentProgressIsPrunedAfterRetention() throws {
        let id = try store.enqueue(Progress(chapterId: 1, page: 1), kind: .kavitaProgress, coalesceKey: "k")
        _ = try store.claimDueJobs(kinds: [.kavitaProgress])
        try store.markSent(id)

        clock.advance(OutboxStore.sentProgressRetention - 1)
        #expect(try store.pruneSentProgress() == 0)
        clock.advance(2)
        #expect(try store.pruneSentProgress() == 1)
    }

    @Test func summaryCountsInFlightAsPending() throws {
        try store.enqueue(Card(expression: "a"), kind: .ankiNote)
        try store.enqueue(Card(expression: "b"), kind: .ankiNote)
        _ = try store.claimDueJobs(kinds: [.ankiNote], limit: 1)
        #expect(try store.summary() == OutboxSummary(pending: 2, failed: 0))
    }
}

@Suite struct ObservationTests {
    @Test func summaryStreamEmitsOnChange() async throws {
        let store = OutboxStore(database: try AppDatabase.inMemory())
        var iterator = store.observeSummary().makeAsyncIterator()
        #expect(try await iterator.next() == .empty)
        try store.enqueue(Card(expression: "a"), kind: .ankiNote)
        #expect(try await iterator.next() == OutboxSummary(pending: 1, failed: 0))
    }
}
