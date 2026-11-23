@testable import AppCommon
import Core
import Foundation
import Testing

/// What Waiting to Sync shows for a job: a wait reads as waiting, never as a retry or a problem.
@Suite struct OutboxStatusTests {
    func job(_ state: OutboxJobState, attempts: Int = 0, error: String? = nil, waiting: String? = nil) -> OutboxJob {
        OutboxJob(kind: .kavitaReadingList, payload: Data(), state: state, attempts: attempts, lastError: error, waitingFor: waiting,
                  nextAttemptAt: .now, createdAt: .now, updatedAt: .now)
    }

    @Test func aWaitShowsAsWaitingWithItsReason() {
        let waiting = job(.pending, waiting: "Waiting for an earlier change.")
        #expect(waiting.stateLabel == "Waiting")
        #expect(waiting.waitingLine == "Waiting for an earlier change.")
        // One that had failed before and now waits: still a wait, not "Attempt 2: …".
        let after = job(.pending, attempts: 2, error: "timed out", waiting: "Waiting for an earlier change.")
        #expect(after.stateLabel == "Waiting")
        #expect(after.waitingLine != nil)
    }

    @Test func retriesAndFailuresAreUnchanged() {
        #expect(job(.pending).stateLabel == "Queued")
        #expect(job(.pending, attempts: 1, error: "offline").stateLabel == "Waiting to retry")
        #expect(job(.pending, attempts: 1, error: "offline").waitingLine == nil)
        #expect(job(.failed, attempts: 1, error: "refused").stateLabel == "Needs attention")
        #expect(job(.failed, attempts: 1, error: "refused", waiting: "stale").waitingLine == nil)
    }
}
