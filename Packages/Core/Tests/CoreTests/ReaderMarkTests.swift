import Foundation
@testable import Core
import Testing

/// How Kavita's list and the device's bookmarks and highlights come together.
@Suite struct ReaderMarkMergeTests {
    let account = "https://kavita.example#reader"

    func mark(_ id: Int64?, _ kind: ReaderMark.Kind = .highlight, serverId: Int? = nil, page: Int = 1, note: String? = nil,
              state: ReaderMark.State = .synced) -> ReaderMark {
        ReaderMark(id: id, account: account, kind: kind, serverId: serverId, libraryId: 1, seriesId: 2, volumeId: 3, chapterId: 4,
                   page: page, text: "テスト", note: note, state: state, createdAt: .distantPast, updatedAt: .distantPast)
    }

    @Test func theServersCopyWinsOverSyncedRows() {
        let plan = ReaderMarkMerge.plan(local: [mark(1, serverId: 10, note: "old")], server: [mark(nil, serverId: 10, note: "new")])
        #expect(plan.save.map(\.id) == [1] && plan.save.first?.note == "new")
        #expect(plan.delete.isEmpty)
    }

    @Test func removedOnAnotherDeviceGoesHereToo() {
        let plan = ReaderMarkMerge.plan(local: [mark(1, serverId: 10)], server: [])
        #expect(plan.delete == [1])
    }

    @Test func madeOnAnotherDeviceIsAdded() {
        let plan = ReaderMarkMerge.plan(local: [], server: [mark(nil, serverId: 10)])
        #expect(plan.save.count == 1 && plan.save[0].id == nil && plan.save[0].state == .synced)
    }

    @Test func unsentChangesStay() {
        let local = [mark(1, state: .pendingCreate), mark(2, serverId: 20, note: "mine", state: .pendingUpdate), mark(3, serverId: 30, state: .pendingDelete)]
        let server = [mark(nil, serverId: 20, note: "theirs"), mark(nil, serverId: 30)]
        let plan = ReaderMarkMerge.plan(local: local, server: server)
        #expect(plan.save.isEmpty && plan.delete.isEmpty, "the edit is sent over theirs; the removal still to go")
    }

    @Test func anEditToOneRemovedElsewhereMakesItAgain() {
        let plan = ReaderMarkMerge.plan(local: [mark(2, serverId: 20, note: "mine", state: .pendingUpdate)], server: [])
        #expect(plan.recreated == [2])
        #expect(plan.save.first?.state == .pendingCreate && plan.save.first?.serverId == nil && plan.save.first?.note == "mine")
    }

    @Test func aRemovalOfOneAlreadyGoneFinishes() {
        let plan = ReaderMarkMerge.plan(local: [mark(3, serverId: 30, state: .pendingDelete)], server: [])
        #expect(plan.delete == [3])
    }

    @Test func thePageBookmarkedOnTwoDevicesIsOne() {
        let plan = ReaderMarkMerge.plan(local: [mark(1, .pageBookmark, page: 5, state: .pendingCreate)],
                                        server: [mark(nil, .pageBookmark, serverId: 9, page: 5)])
        #expect(plan.save.count == 1 && plan.save[0].id == 1 && plan.save[0].state == .synced)
    }

    @Test func theStoreQueuesTheRemadeOnesAndKeepsAccountsApart() throws {
        let database = try AppDatabase.inMemory()
        let store = ReaderMarkStore(database: database), outbox = OutboxStore(database: database)
        var edited = try store.add(mark(nil, serverId: nil), outbox: outbox)
        try store.didSend(edited, serverId: 20)
        try store.edit(edited.id!, note: "mine", slot: 3, outbox: outbox)
        edited = try #require(try store.mark(edited.id!))
        var other = mark(nil, serverId: 99)
        other.account = "https://other.example#someone"
        _ = try store.add(other, outbox: outbox)

        let again = try store.merge([], account: account, kinds: [.highlight], scope: { $0.seriesId == 2 }, outbox: outbox)
        #expect(again.map(\.id) == [edited.id])
        #expect(try store.mark(edited.id!)?.state == .pendingCreate)
        #expect(try store.marks(account: other.account, seriesId: 2).count == 1, "another account's marks aren't touched")
        #expect(try outbox.waitingCounts()[.kavitaReaderMark] == 2)
    }

    @Test func aMadeAndThenRemovedMarkIsHiddenAtOnce() throws {
        let database = try AppDatabase.inMemory()
        let store = ReaderMarkStore(database: database), outbox = OutboxStore(database: database)
        let made = try store.add(mark(nil, .pageBookmark, page: 7), outbox: outbox)
        try store.remove(made.id!, outbox: outbox)
        #expect(try store.marks(account: account, seriesId: 2).isEmpty)
        #expect(try outbox.waitingCounts()[.kavitaReaderMark] == 1, "one job for the mark")
    }

    @Test func whatTheServerCantDoIsRemembered() throws {
        let database = try AppDatabase.inMemory()
        let store = ReaderMarkStore(database: database), outbox = OutboxStore(database: database)
        #expect(try store.isAvailable(.annotations, account: account))
        _ = try store.add(mark(nil), outbox: outbox)
        try store.setAvailable(false, .annotations, account: account)
        #expect(try !store.isAvailable(.annotations, account: account))
        #expect(try store.marks(account: account, seriesId: 2).isEmpty, "unsent highlights go with it")
        try store.setAvailable(true, .annotations, account: account)
        #expect(try store.isAvailable(.annotations, account: account))
    }
}
