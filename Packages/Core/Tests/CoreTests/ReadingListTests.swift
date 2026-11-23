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

    // MARK: Read state

    func listedRead(_ chapter: Int, read: Int, pages: Int = 20, at: Date?) -> ReadingListStore.ListedItem {
        .init(serverItemId: 100 + chapter, chapter: self.chapter(chapter), pagesRead: read, pages: pages, readAt: at)
    }

    func entry(_ store: ReadingListStore, _ id: Int64, _ chapter: Int) throws -> ReadingListEntry {
        try #require(try store.entries(listId: id).first { $0.item.chapterId == chapter })
    }

    @Test func readStateFollowsTheSeriesPagesRule() throws {
        let (store, _) = try stores()
        let id = try abcd(store)
        let progress = ReadingProgressStore(database: store.database)
        let earlier = Date(timeIntervalSince1970: 1_800_000_000), later = earlier.addingTimeInterval(600)
        try store.mergeItems([listedRead(1, read: 20, at: earlier), listedRead(2, read: 0, at: nil), listedRead(3, read: 20, at: later),
                              listedRead(4, read: 5, at: earlier)], listId: id)
        // 1: Kavita says read, nothing here.
        #expect(try entry(store, id, 1).isRead)
        // 2: never read on Kavita, read to the end here: read.
        try progress.save(LocalReadingProgress(chapterId: 2, seriesId: 20, volumeId: 200, libraryId: 1, page: 19, pages: 20, updatedAt: earlier))
        #expect(try entry(store, id, 2).isRead)
        // 3: marked unread here before Kavita's read was newer: Kavita's newer read wins.
        try progress.save(LocalReadingProgress(chapterId: 3, seriesId: 30, volumeId: 300, libraryId: 1, page: 0, pages: 20, updatedAt: earlier))
        #expect(try entry(store, id, 3).isRead)
        // 4: Kavita at page 5 earlier, marked unread here later: this device's newer row wins (the
        // same as the series page).
        try progress.save(LocalReadingProgress(chapterId: 4, seriesId: 40, volumeId: 400, libraryId: 1, page: 0, pages: 20, updatedAt: later))
        #expect(try entry(store, id, 4).pagesRead == 0)
        // An unsent add with nothing known: no mark.
        let (other, outbox) = try stores()
        let list = try abcd(other)
        try other.set(true, chapter: chapter(7), listId: list, outbox: outbox)
        #expect(try entry(other, list, 7).pagesRead == nil)
    }

    @Test func readingHereShowsAtOnceAndAnOlderListDoesntPutAMarkBack() async throws {
        let (store, _) = try stores()
        let id = try abcd(store)
        let progress = ReadingProgressStore(database: store.database)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        try store.mergeItems((1...4).map { listedRead($0, read: 20, at: t0) }, listId: id)
        // Marked unread here (the progress row the marking writes): the list shows it at once,
        // through the same observation.
        var stream = store.observeEntries(listId: id).makeAsyncIterator()
        #expect(try await stream.next()?.first { $0.item.chapterId == 1 }?.isRead == true)
        try progress.save(LocalReadingProgress(chapterId: 1, seriesId: 10, volumeId: 100, libraryId: 1, page: 0, pages: 20,
                                               updatedAt: t0.addingTimeInterval(60)))
        #expect(try await stream.next()?.first { $0.item.chapterId == 1 }?.isRead == false)
        // A list read before that, merged after: still unread.
        try store.mergeItems((1...4).map { listedRead($0, read: 20, at: t0) }, listId: id, listedAt: t0.addingTimeInterval(30))
        #expect(try !entry(store, id, 1).isRead)
        // Kavita's reading kept is never replaced by an older one.
        try store.mergeItems([listedRead(1, read: 20, at: t0.addingTimeInterval(120))] + (2...4).map { listedRead($0, read: 20, at: t0) }, listId: id)
        try store.mergeItems((1...4).map { listedRead($0, read: 3, at: t0) }, listId: id)
        #expect(try entry(store, id, 1).item.kavitaReadAt == t0.addingTimeInterval(120))
        #expect(try entry(store, id, 1).isRead, "Kavita's newer read (120 s) wins over this device's (60 s)")
    }

    // MARK: The one rule (whose place wins)

    /// Kavita read the chapter to the end at `t0`; this device has it at page 3 (or as given),
    /// saved at `localAt`.
    func placeSetup(localAt: Date, localPage: Int = 3) throws -> (ReadingListStore, OutboxStore, Int64) {
        let (store, outbox) = try stores()
        let id = try abcd(store)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        try store.mergeItems((1...4).map { listedRead($0, read: $0 == 1 ? 3 : 20, at: t0) }, listId: id)
        try ReadingProgressStore(database: store.database).save(LocalReadingProgress(
            chapterId: 1, seriesId: 10, volumeId: 100, libraryId: 1, page: localPage, pages: 20, updatedAt: localAt))
        return (store, outbox, id)
    }

    @Test func aQueuedChangeKeepsThisDevicesPlaceEvenIfKavitaIsNewer() throws {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        // Read to the end here while offline on a clock that's behind: older than Kavita's page 3.
        let (store, outbox, id) = try placeSetup(localAt: t0.addingTimeInterval(-600), localPage: 19)
        try outbox.enqueue(Progress(chapterId: 1, page: 19), kind: .kavitaProgress, coalesceKey: "kavita.chapter.1")
        #expect(try entry(store, id, 1).isRead, "a queued chapter change: this device's")
        _ = try outbox.claimDueJobs(kinds: [.kavitaProgress])
        #expect(try entry(store, id, 1).isRead, "being sent: still this device's")
        try outbox.markSent(try #require(try outbox.jobs(states: [.inFlight]).first?.id))
        #expect(try !entry(store, id, 1).isRead, "sent (or skipped): the newer place, Kavita's")
    }

    @Test func aQueuedSeriesChangeKeepsThisDevicesPlace() throws {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let (store, outbox, id) = try placeSetup(localAt: t0.addingTimeInterval(-600), localPage: 19)
        try outbox.enqueue(Progress(chapterId: 0, page: 0), kind: .kavitaProgress, coalesceKey: "kavita.series.10")
        #expect(try entry(store, id, 1).isRead)
    }

    @Test func withNothingQueuedTheNewerPlaceWinsBothWays() throws {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        // Kavita newer with fewer pages (marked unread or read less far elsewhere): Kavita's.
        let (older, _, a) = try placeSetup(localAt: t0.addingTimeInterval(-600), localPage: 19)
        #expect(try entry(older, a, 1).pagesRead == 3)
        // This device newer: its.
        let (newer, _, b) = try placeSetup(localAt: t0.addingTimeInterval(600), localPage: 19)
        #expect(try entry(newer, b, 1).isRead)
    }

    @Test func aChangeThatFailedForGoodNoLongerProtectsThePlace() throws {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let (store, outbox, id) = try placeSetup(localAt: t0.addingTimeInterval(-600), localPage: 19)
        let job = try outbox.enqueue(Progress(chapterId: 1, page: 19), kind: .kavitaProgress, coalesceKey: "kavita.chapter.1")
        try outbox.markFailed(job, error: "refused")
        #expect(try entry(store, id, 1).pagesRead == 3, "dates decide")
    }

    @Test func theListChangesWhenAChangeLeavesTheQueue() async throws {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let (store, outbox, id) = try placeSetup(localAt: t0.addingTimeInterval(-600), localPage: 19)
        let job = try outbox.enqueue(Progress(chapterId: 1, page: 19), kind: .kavitaProgress, coalesceKey: "kavita.chapter.1")
        var stream = store.observeEntries(listId: id).makeAsyncIterator()
        #expect(try await stream.next()?.first { $0.item.chapterId == 1 }?.isRead == true)
        _ = try outbox.claimDueJobs(kinds: [.kavitaProgress])
        try outbox.markSent(job)
        var flipped = false
        for _ in 0..<3 {
            if try await stream.next()?.first(where: { $0.item.chapterId == 1 })?.isRead == false { flipped = true; break }
        }
        #expect(flipped, "the observation follows the queue")
    }
}
