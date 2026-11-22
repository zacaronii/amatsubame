import Foundation
import Synchronization
@testable import Core
import Testing

/// Want to Read on the device: Kavita's list, and toggles waiting to be sent.
@Suite struct WantToReadTests {
    let account = "https://kavita.example#reader"

    func stores() throws -> (WantToReadStore, OutboxStore) {
        let database = try AppDatabase.inMemory()
        return (WantToReadStore(database: database), OutboxStore(database: database))
    }

    @Test func aToggleShowsAtOnceAndIsQueuedOnce() throws {
        let (store, outbox) = try stores()
        try store.set(true, seriesId: 7, account: account, outbox: outbox)
        #expect(try store.isWanted(account: account, seriesId: 7))
        try store.set(true, seriesId: 7, account: account, outbox: outbox)
        try store.set(false, seriesId: 7, account: account, outbox: outbox)
        try store.set(true, seriesId: 7, account: account, outbox: outbox)
        #expect(try outbox.waitingCounts()[.kavitaWantToRead] == 1, "toggles of one series share a job")
        #expect(try store.wanted(account: account) == [7])
    }

    @Test func aRefreshDoesntUndoAnUnsentToggle() throws {
        let (store, outbox) = try stores()
        try store.merge([1, 2, 3], account: account)
        try store.set(false, seriesId: 2, account: account, outbox: outbox)
        try store.set(true, seriesId: 9, account: account, outbox: outbox)
        try store.merge([1, 2, 3], account: account)
        #expect(try store.wanted(account: account) == [9, 1, 3], "added first, removed stays removed, Kavita's order after")
        try store.merge([3, 1], account: account)
        #expect(try store.wanted(account: account) == [9, 3, 1], "Kavita's list replaces the synced ones")
    }

    @Test func sentTogglesSettle() throws {
        let (store, outbox) = try stores()
        try store.merge([1], account: account)
        try store.set(false, seriesId: 1, account: account, outbox: outbox)
        try store.set(true, seriesId: 5, account: account, outbox: outbox)
        try store.didSend(try #require(try store.row(account: account, seriesId: 1)))
        try store.didSend(try #require(try store.row(account: account, seriesId: 5)))
        #expect(try store.row(account: account, seriesId: 1)?.state == .removed, "kept as removed until a later list")
        #expect(try store.wanted(account: account) == [5])
        #expect(try store.row(account: account, seriesId: 5)?.state == .synced)
    }

    @Test func aToggleWhileOneWasOnItsWayStaysPending() throws {
        let (store, outbox) = try stores()
        try store.set(true, seriesId: 5, account: account, outbox: outbox)
        let sending = try #require(try store.row(account: account, seriesId: 5))
        try store.set(false, seriesId: 5, account: account, outbox: outbox)
        try store.didSend(sending)
        #expect(try store.row(account: account, seriesId: 5)?.state == .pendingRemove)
    }

    @Test func theSeriesPagesCheckOnlyFillsWhatIsntPending() throws {
        let (store, outbox) = try stores()
        try store.note(true, seriesId: 4, account: account)
        #expect(try store.isWanted(account: account, seriesId: 4))
        try store.set(false, seriesId: 4, account: account, outbox: outbox)
        try store.note(true, seriesId: 4, account: account)
        #expect(try !store.isWanted(account: account, seriesId: 4), "the unsent removal wins")
    }

    @Test func accountsAreKeptApart() throws {
        let (store, outbox) = try stores()
        try store.set(true, seriesId: 1, account: account, outbox: outbox)
        try store.merge([2], account: "https://other.example#someone")
        #expect(try store.wanted(account: account) == [1])
        #expect(try store.wanted(account: "https://other.example#someone") == [2])
        try store.dropUnsent(account: account)
        #expect(try store.wanted(account: account).isEmpty)
        #expect(try store.wanted(account: "https://other.example#someone") == [2])
    }
}

/// Toggles whose job is gone (cleared in Waiting to Sync), and lists that were on their way
/// while a toggle reached Kavita.
@Suite struct WantToReadSettlingTests {
    let account = "https://kavita.example#reader"

    @Test func clearedTogglesFollowKavitaAgainBothWays() throws {
        let database = try AppDatabase.inMemory()
        let store = WantToReadStore(database: database), outbox = OutboxStore(database: database)
        try store.merge([1, 2], account: account)
        try store.set(false, seriesId: 1, account: account, outbox: outbox)
        try store.set(true, seriesId: 3, account: account, outbox: outbox)
        try store.merge([1, 2], account: account)
        #expect(try store.wanted(account: account) == [3, 2], "while their jobs wait, the toggles stand")
        try outbox.cancelAll(kind: .kavitaWantToRead)
        try store.merge([1, 2], account: account)
        #expect(try store.wanted(account: account) == [1, 2], "cleared: Kavita's list again, both directions")
        // The series page's check too.
        try store.set(true, seriesId: 4, account: account, outbox: outbox)
        try outbox.cancelAll(kind: .kavitaWantToRead)
        try store.note(false, seriesId: 4, account: account)
        #expect(try !store.isWanted(account: account, seriesId: 4))
    }

    @Test func aFailedToggleStillListedStands() throws {
        let database = try AppDatabase.inMemory()
        let store = WantToReadStore(database: database), outbox = OutboxStore(database: database)
        try store.set(true, seriesId: 3, account: account, outbox: outbox)
        let job = try #require(try outbox.claimDueJobs(kinds: [.kavitaWantToRead], limit: 1).first?.job.id)
        try outbox.markFailed(job, error: "refused")
        try store.merge([], account: account)
        #expect(try store.wanted(account: account) == [3])
    }

    @Test func aListFetchedBeforeATogglesSendDoesntUndoIt() throws {
        let database = try AppDatabase.inMemory()
        let clock = Mutex(Date(timeIntervalSince1970: 1_000))
        let store = WantToReadStore(database: database, now: { clock.withLock { $0 } })
        let outbox = OutboxStore(database: database)
        try store.merge([5], account: account)
        // The list is fetched (still with 5) ...
        let listedAt = clock.withLock { $0 }
        clock.withLock { $0 = $0.addingTimeInterval(1) }
        // ... while 5's removal and 6's addition reach Kavita ...
        try store.set(false, seriesId: 5, account: account, outbox: outbox)
        try store.set(true, seriesId: 6, account: account, outbox: outbox)
        try store.didSend(try #require(try store.row(account: account, seriesId: 5)))
        try store.didSend(try #require(try store.row(account: account, seriesId: 6)))
        try outbox.cancelAll(kind: .kavitaWantToRead)
        // ... and the older list arrives.
        try store.merge([5], account: account, listedAt: listedAt)
        #expect(try store.wanted(account: account) == [6], "neither undone")
        // A list fetched afterwards settles them.
        clock.withLock { $0 = $0.addingTimeInterval(1) }
        try store.merge([6], account: account, listedAt: clock.withLock { $0 })
        #expect(try store.wanted(account: account) == [6])
        #expect(try store.row(account: account, seriesId: 5) == nil, "the removal's record goes")
    }

    @Test func aRowAndItsJobAreWrittenTogether() throws {
        let database = try AppDatabase.inMemory()
        let outbox = OutboxStore(database: database)
        struct Stop: Error {}
        #expect(throws: Stop.self) {
            try database.writer.write { db in
                try outbox.enqueue(WantToReadJob(account: account, seriesId: 1), kind: .kavitaWantToRead, coalesceKey: "k", in: db)
                throw Stop()
            }
        }
        #expect(try outbox.waitingCounts()[.kavitaWantToRead] == nil, "rolled back with the write it was in")
        let store = WantToReadStore(database: database)
        try store.set(true, seriesId: 1, account: account, outbox: outbox)
        let waiting = try database.reader.read { db in try WantToReadStore.waiting(db, try WantToReadRow.fetchAll(db)) }
        #expect(waiting == [1], "the row is never without its job")
    }

    @Test func aSettledToggleIsntSettledAgain() throws {
        let database = try AppDatabase.inMemory()
        let store = WantToReadStore(database: database), outbox = OutboxStore(database: database)
        try store.merge([5], account: account)
        try store.set(false, seriesId: 5, account: account, outbox: outbox)
        let sent = try #require(try store.row(account: account, seriesId: 5))
        try store.didSend(sent)
        try store.didSend(sent)
        #expect(try store.row(account: account, seriesId: 5)?.state == .removed, "not turned back into wanted")
        #expect(try !store.isWanted(account: account, seriesId: 5))
    }
}
