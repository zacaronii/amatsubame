import Foundation
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
        #expect(try store.row(account: account, seriesId: 1) == nil)
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
