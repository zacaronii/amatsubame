import Foundation
import GRDB
@testable import Core
import Testing

/// Reading lists on the device: Kavita's lists and items, and the changes and moves waiting.
@Suite struct ReadingListTests {
    let account = "https://kavita.example#reader"

    func stores() throws -> (ReadingListStore, OutboxStore) {
        let database = try AppDatabase.inMemory()
        return (ReadingListStore(database: database), OutboxStore(database: database))
    }

    func chapter(_ id: Int, format: Int = 1) -> ReadingListChapter {
        ReadingListChapter(chapterId: id, seriesId: id * 10, volumeId: id * 100, libraryId: 1, format: format, seriesName: "Series \(id)", title: "Vol. \(id)")
    }

    func listed(_ id: Int, _ title: String, own: Bool = true, synced: Bool = false, items: Int? = 4) -> ReadingListStore.Listed {
        ReadingListStore.Listed(serverId: id, title: title, isOwn: own, owner: own ? "reader" : "admin", promoted: !own, isSynced: synced, itemCount: items)
    }

    /// A list on Kavita with items A B C D (chapters 1–4).
    func abcd(_ store: ReadingListStore) throws -> Int64 {
        try store.merge([listed(9, "Mine")], account: account)
        let id = try #require(try store.lists(account: account).first).id!
        try store.mergeItems((1...4).map { .init(serverItemId: 100 + $0, chapter: chapter($0)) }, listId: id)
        return id
    }

    func order(_ store: ReadingListStore, _ id: Int64) throws -> [Int] { try store.items(listId: id).map(\.chapterId) }

    @Test func movesKeepTheirOrderAndOnlyTheSameItemInARowCoalesces() throws {
        let (store, outbox) = try stores()
        let id = try abcd(store)
        try store.move(1, after: 4, listId: id, outbox: outbox)      // B C D A
        try store.move(2, after: 1, listId: id, outbox: outbox)      // C D A B
        try store.move(1, after: nil, listId: id, outbox: outbox)    // A C D B
        #expect(try order(store, id) == [1, 3, 4, 2], "shown with the waiting moves applied")
        #expect(try outbox.waitingCounts()[.kavitaReadingList] == 3, "A's last move isn't folded into its first")
        // Kavita, taking them in order, ends where the device shows.
        var kavita = [1, 2, 3, 4]
        let database = store.database
        let moves = try database.reader.read { try ReadingListMoveRow.order(Column("id")).fetchAll($0) }
        for move in moves { kavita = ReadingListStore.apply(move.chapterId, after: move.anchorChapters, to: kavita) }
        #expect(kavita == [1, 3, 4, 2])

        // The same item moved twice in a row: one move, one job.
        let (other, otherOutbox) = try stores()
        let list = try abcd(other)
        try other.move(1, after: 2, listId: list, outbox: otherOutbox)
        try other.move(1, after: 3, listId: list, outbox: otherOutbox)
        #expect(try otherOutbox.waitingCounts()[.kavitaReadingList] == 1)
        #expect(try order(other, list) == [2, 3, 1, 4])
    }

    @Test func aMoveKeepsItsFallbackChain() throws {
        let (store, outbox) = try stores()
        let id = try abcd(store)
        try store.move(4, after: 2, listId: id, outbox: outbox)
        let move = try #require(try store.database.reader.read { try ReadingListMoveRow.fetchOne($0) })
        #expect(move.anchorChapters == [2, 1], "nearest first, as the list stood")
        // Its anchor gone on Kavita: it goes after the next one in the chain.
        #expect(ReadingListStore.apply(4, after: move.anchorChapters, to: [1, 3, 4]) == [1, 4, 3])
        #expect(ReadingListStore.apply(4, after: move.anchorChapters, to: [3, 4]) == [4, 3], "none left: first")
    }

    @Test func aRefreshDoesntUndoAWaitingMove() throws {
        let (store, outbox) = try stores()
        let id = try abcd(store)
        try store.move(1, after: 4, listId: id, outbox: outbox)
        try store.mergeItems((1...4).map { .init(serverItemId: 100 + $0, chapter: chapter($0)) }, listId: id)
        #expect(try order(store, id) == [2, 3, 4, 1])
        try outbox.cancelAll(kind: .kavitaReadingList)
        try store.mergeItems((1...4).map { .init(serverItemId: 100 + $0, chapter: chapter($0)) }, listId: id)
        #expect(try order(store, id) == [1, 2, 3, 4], "cleared: Kavita's order again")
    }

    @Test func takingOutAnUnsentAddCancelsIt() throws {
        let (store, outbox) = try stores()
        let id = try abcd(store)
        try store.set(true, chapter: chapter(7), listId: id, outbox: outbox)
        #expect(try order(store, id) == [1, 2, 3, 4, 7], "added at the end, as Kavita does")
        try store.set(false, chapter: chapter(7), listId: id, outbox: outbox)
        #expect(try store.item(listId: id, chapterId: 7) == nil)
        #expect(try (outbox.waitingCounts()[.kavitaReadingList] ?? 0) == 0)
        #expect(try store.itemCount(listId: id) == 4)
    }

    @Test func theItemCountIsKnownOnlyWhenItAddsUp() throws {
        let (store, outbox) = try stores()
        let id = try abcd(store)
        try store.set(false, chapter: chapter(1), listId: id, outbox: outbox)
        #expect(try store.itemCount(listId: id) == 3)
        try store.merge([listed(9, "Mine", items: 2)], account: account)
        #expect(try store.itemCount(listId: id) == nil, "read earlier, Kavita now says fewer")
        try store.merge([listed(9, "Mine", items: nil)], account: account)
        #expect(try store.itemCount(listId: id) == nil, "Kavita before 0.8.4 doesn't say")
    }

    @Test func anEmptiedListIsMadeAgainButOneWithItemsWasDeletedElsewhere() throws {
        let (store, outbox) = try stores()
        try store.merge([listed(9, "Emptied", items: 0), listed(10, "Full", items: 3)], account: account)
        let rows = try store.lists(account: account)
        let emptied = try #require(rows.first { $0.title == "Emptied" }).id!
        let full = try #require(rows.first { $0.title == "Full" }).id!
        #expect(try store.recreate(emptied, outbox: outbox))
        #expect(try store.list(emptied)?.state == .pendingCreate)
        #expect(try !store.recreate(full, outbox: outbox))
        // At most twice.
        try store.didCreate(emptied, serverId: 11)
        #expect(try store.recreate(emptied, outbox: outbox))
        try store.didCreate(emptied, serverId: 12)
        #expect(try !store.recreate(emptied, outbox: outbox))
    }

    @Test func aRefreshAdoptsAWaitingCreateAndReadOnlyIsRefused() throws {
        let (store, outbox) = try stores()
        let made = try store.create(title: " Later ", with: chapter(1), account: account, outbox: outbox)
        #expect(throws: ReadingListError.titleTaken("LATER")) { try store.create(title: "LATER", with: chapter(2), account: account, outbox: outbox) }
        try store.merge([listed(9, "later", items: 0), listed(10, "Shared", own: false), listed(11, "Synced", synced: true)], account: account)
        #expect(try store.list(made.id!)?.serverId == 9, "adopted, not listed twice")
        #expect(try store.lists(account: account).count == 3)
        for row in try store.lists(account: account) where row.title != "later" {
            #expect(throws: ReadingListError.readOnly(row.title)) { try store.set(true, chapter: chapter(3), listId: row.id!, outbox: outbox) }
            #expect(throws: ReadingListError.readOnly(row.title)) { try store.move(1, after: nil, listId: row.id!, outbox: outbox) }
            #expect(throws: ReadingListError.readOnly(row.title)) { try store.delete(row.id!, outbox: outbox) }
        }
    }

    @Test func deletingCancelsItsWaitingChanges() throws {
        let (store, outbox) = try stores()
        let id = try abcd(store)
        try store.set(true, chapter: chapter(7), listId: id, outbox: outbox)
        try store.move(1, after: 4, listId: id, outbox: outbox)
        try store.delete(id, outbox: outbox)
        #expect(try outbox.waitingCounts()[.kavitaReadingList] == 1, "only the delete")
        #expect(try store.lists(account: account).isEmpty)
    }

    // MARK: Next in list

    func next(_ store: ReadingListStore, after chapter: Int, _ id: Int64, skip: (ReadingListItemRow) -> String? = { _ in nil }) throws -> ReadingListNext {
        try store.next(after: chapter, listId: id, skip: skip)
    }

    func nextChapter(_ result: ReadingListNext) -> Int? {
        if case .item(let row, _) = result { return row.chapterId }
        return nil
    }

    @Test func nextFollowsTheListAcrossSeries() throws {
        let (store, _) = try stores()
        let id = try abcd(store)    // chapters 1–4, each its own series
        #expect(nextChapter(try next(store, after: 1, id)) == 2)
        #expect(try next(store, after: 4, id) == .end(skipped: []))
    }

    @Test func nextPassesOverWhatCantBeOpenedWithItsReason() throws {
        let (store, _) = try stores()
        let id = try abcd(store)
        let result = try next(store, after: 1, id) { [2: "PDF", 3: "hidden library"][$0.chapterId] }
        guard case .item(let row, let skipped) = result else { Issue.record("no next"); return }
        #expect(row.chapterId == 4)
        #expect(skipped == ["PDF", "hidden library"])
        #expect(try next(store, after: 3, id) { $0.chapterId == 4 ? "PDF" : nil } == .end(skipped: ["PDF"]))
    }

    @Test func nextFollowsWaitingMovesAndUnsentAdds() throws {
        let (store, outbox) = try stores()
        let id = try abcd(store)
        try store.move(4, after: 1, listId: id, outbox: outbox)            // 1 4 2 3
        try store.set(true, chapter: chapter(7), listId: id, outbox: outbox)   // 1 4 2 3 7
        #expect(nextChapter(try next(store, after: 1, id)) == 4, "the device's order, not Kavita's last read")
        #expect(nextChapter(try next(store, after: 3, id)) == 7, "an unsent add is offered")
    }

    @Test func anItemBeingTakenOutIsNeverOffered() throws {
        let (store, outbox) = try stores()
        let id = try abcd(store)
        try store.set(false, chapter: chapter(2), listId: id, outbox: outbox)
        #expect(nextChapter(try next(store, after: 1, id)) == 3)
    }

    @Test func theItemReadTakenOutOrTheListGoneIsNotInList() throws {
        let (store, outbox) = try stores()
        let id = try abcd(store)
        try store.set(false, chapter: chapter(2), listId: id, outbox: outbox)
        #expect(try next(store, after: 2, id) == .notInList, "taken out here while it's read")
        try store.mergeItems([1, 3, 4].map { .init(serverItemId: 100 + $0, chapter: chapter($0)) }, listId: id)
        #expect(try next(store, after: 2, id) == .notInList, "or by a refresh")
        try store.delete(id, outbox: outbox)
        #expect(try next(store, after: 1, id) == .notInList, "the list deleted")
        #expect(try next(store, after: 1, 999) == .notInList, "or gone")
    }
}
