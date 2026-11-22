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

    @Test func whatTheServerCantDoIsRememberedAndTypedNotesAreKept() throws {
        let database = try AppDatabase.inMemory()
        let store = ReaderMarkStore(database: database), outbox = OutboxStore(database: database)
        #expect(try store.isAvailable(.annotations, account: account))
        let note = try store.add(mark(nil, note: "typed offline"), outbox: outbox)
        _ = try store.add(mark(nil, .pageBookmark, page: 9), outbox: outbox)
        try store.setAvailable(false, .annotations, account: account)
        try store.setAvailable(false, .pageBookmarks, account: account)
        #expect(try !store.isAvailable(.annotations, account: account))
        let left = try store.marks(account: account, seriesId: 2)
        #expect(left.map(\.id) == [note.id], "the highlight and its note stay; the page bookmark held nothing typed")
        #expect(left.first?.state == .pendingCreate)

        // Found with annotations later (the server was upgraded): the highlight is queued again.
        let queued = try outbox.waitingCounts()[.kavitaReaderMark] ?? 0
        try database.writer.write { try $0.execute(sql: "DELETE FROM outboxJob") }
        try store.setAvailable(true, .annotations, account: account, outbox: outbox)
        #expect(queued > 0)
        #expect(try store.isAvailable(.annotations, account: account))
        #expect(try outbox.waitingCounts()[.kavitaReaderMark] == 1)
    }

    @Test func clearedChangesFollowTheServerAgain() throws {
        let database = try AppDatabase.inMemory()
        let store = ReaderMarkStore(database: database), outbox = OutboxStore(database: database)
        let made = try store.add(mark(nil, .pageBookmark, page: 3), outbox: outbox)
        var kept = try store.add(mark(nil, .pageBookmark, page: 8), outbox: outbox)
        try store.didSend(kept, serverId: 9)
        try store.remove(kept.id!, outbox: outbox)
        _ = try outbox.cancelAll(kind: .kavitaReaderMark)
        try store.merge([mark(nil, .pageBookmark, serverId: 9, page: 8)], account: account, kinds: [.pageBookmark],
                        scope: { $0.seriesId == 2 }, outbox: outbox)
        let left = try store.marks(account: account, seriesId: 2)
        #expect(try store.mark(made.id!) == nil, "a make that won't reach the server goes")
        kept = try #require(left.first)
        #expect(left.count == 1 && kept.page == 8 && kept.state == .synced, "a removal that won't reach it: the server's copy is back")
    }

    @Test func bookmarkingAPageAgainBeforeItsRemovalWentTakesTheSameRowBack() throws {
        let database = try AppDatabase.inMemory()
        let store = ReaderMarkStore(database: database), outbox = OutboxStore(database: database)
        let first = try store.add(mark(nil, .pageBookmark, page: 5), outbox: outbox)
        try store.didSend(first, serverId: nil)
        try store.remove(first.id!, outbox: outbox)
        let again = try store.add(mark(nil, .pageBookmark, page: 5), outbox: outbox)
        #expect(again.id == first.id, "one row")
        #expect(again.state == .pendingCreate)
        #expect(try outbox.waitingCounts()[.kavitaReaderMark] == 1, "one job: a retried removal can't go after the make")
        #expect(try store.marks(account: account, seriesId: 2).count == 1)
    }

    @Test func aRemovalThatRacedABookmarkAgainLeavesTheRow() throws {
        let database = try AppDatabase.inMemory()
        let store = ReaderMarkStore(database: database), outbox = OutboxStore(database: database)
        let first = try store.add(mark(nil, .pageBookmark, page: 5), outbox: outbox)
        try store.didSend(first, serverId: nil)
        try store.remove(first.id!, outbox: outbox)
        let sending = try #require(try store.mark(first.id!))
        // Bookmarked again while the removal is with the server.
        _ = try store.add(mark(nil, .pageBookmark, page: 5), outbox: outbox)
        try store.didRemove(sending)
        #expect(try store.mark(first.id!)?.state == .pendingCreate, "its own job makes it again")
    }

    /// A highlight kept without a job (the server too old) is a row on disk like any other: it's
    /// there after the app starts again, and after signing out and back in to the same account.
    @Test func aKeptHighlightOutlivesARestartAndSigningInAgain() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "marks-\(UUID())")
        let server = URL(string: "https://kavita.example")!
        var note: ReaderMark
        do {
            let database = try AppDatabase.onDisk(directory: directory)
            let store = ReaderMarkStore(database: database), outbox = OutboxStore(database: database)
            let accounts = AccountStore(database: database)
            try accounts.save(ServerAccount(kind: .kavita, baseURL: server, username: "reader"))
            let key = ReaderMarkStore.accountKey(try #require(try accounts.account(.kavita)))
            var made = mark(nil, note: "typed offline")
            made.account = key
            note = try store.add(made, outbox: outbox)
            try store.setAvailable(false, .annotations, account: key)
            try accounts.delete(.kavita)
        }
        // Started again, and signed in to the same server and user.
        let database = try AppDatabase.onDisk(directory: directory)
        let store = ReaderMarkStore(database: database)
        let accounts = AccountStore(database: database)
        try accounts.save(ServerAccount(kind: .kavita, baseURL: server, username: "reader"))
        let key = ReaderMarkStore.accountKey(try #require(try accounts.account(.kavita)))
        let kept = try store.marks(account: key, seriesId: 2)
        #expect(kept.map(\.id) == [note.id] && kept.first?.note == "typed offline" && kept.first?.state == .pendingCreate)
    }
}
