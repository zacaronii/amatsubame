import Foundation
@testable import Core
import Testing

/// Collections on the device: Kavita's lists, and the changes waiting to be sent.
@Suite struct CollectionTests {
    let account = "https://kavita.example#reader"

    func stores() throws -> (CollectionStore, OutboxStore, AppDatabase) {
        let database = try AppDatabase.inMemory()
        return (CollectionStore(database: database), OutboxStore(database: database), database)
    }

    func listed(_ id: Int, _ title: String, own: Bool = true, source: Int = 0, items: Int = 1) -> CollectionStore.Listed {
        CollectionStore.Listed(serverId: id, title: title, isOwn: own, owner: own ? "reader" : "admin", promoted: !own, source: source, itemCount: items)
    }

    @Test func titlesCompareAsKavitaComparesThem() {
        #expect(CollectionRow.normalized("  My Favourite List! ") == "myfavouritelist!")
        #expect(CollectionRow.normalized("夜の-話（2）") == "夜の話2")
        #expect(CollectionRow.normalized("ＡＢ１") == "ａｂ", "full-width letters count, full-width digits don't")
        #expect(CollectionRow.normalized(" - ・ ").isEmpty)
    }

    @Test func aNewCollectionComesWithItsSeriesInOneWrite() throws {
        let (store, outbox, _) = try stores()
        let made = try store.create(title: "  Later  ", with: 7, account: account, outbox: outbox)
        #expect(made.title == "Later" && made.state == .pendingCreate)
        #expect(try outbox.waitingCounts()[.kavitaCollection] == 2, "the create and the add")
        #expect(try store.seriesRow(collectionId: made.id!, seriesId: 7)?.state == .pendingAdd)
        #expect(throws: CollectionError.emptyTitle) { try store.create(title: " ・ ", with: 7, account: account, outbox: outbox) }
        #expect(throws: CollectionError.titleTaken("LATER.")) { try store.create(title: "LATER.", with: 8, account: account, outbox: outbox) }
        _ = try store.create(title: "later!", with: 8, account: account, outbox: outbox)  // "!" counts, as in Kavita
    }

    @Test func readOnlyCollectionsAreRefusedInTheStore() throws {
        let (store, outbox, _) = try stores()
        try store.merge([listed(1, "Promoted", own: false), listed(2, "From AniList", source: 1), listed(3, "Mine")], account: account)
        let rows = try store.collections(account: account)
        for row in rows where row.title != "Mine" {
            #expect(throws: CollectionError.readOnly(row.title)) { try store.set(true, seriesId: 5, collectionId: row.id!, outbox: outbox) }
            #expect(throws: CollectionError.readOnly(row.title)) { try store.delete(row.id!, outbox: outbox) }
        }
        let mine = try #require(rows.first { $0.title == "Mine" })
        try store.set(true, seriesId: 5, collectionId: mine.id!, outbox: outbox)
        #expect(try outbox.waitingCounts()[.kavitaCollection] == 1)
    }

    @Test func deletingCancelsItsWaitingChangesInTheSameWrite() throws {
        let (store, outbox, _) = try stores()
        try store.merge([listed(3, "Mine", items: 2)], account: account)
        let mine = try #require(try store.collections(account: account).first)
        try store.set(true, seriesId: 5, collectionId: mine.id!, outbox: outbox)
        try store.set(true, seriesId: 6, collectionId: mine.id!, outbox: outbox)
        try store.delete(mine.id!, outbox: outbox)
        #expect(try outbox.waitingCounts()[.kavitaCollection] == 1, "only the delete waits")
        #expect(try store.collections(account: account).isEmpty)

        // One never made on Kavita just goes, with its jobs.
        let made = try store.create(title: "Later", with: 7, account: account, outbox: outbox)
        try store.delete(made.id!, outbox: outbox)
        #expect(try store.collection(made.id!) == nil)
        #expect(try outbox.waitingCounts()[.kavitaCollection] == 1)
    }

    @Test func aRefreshKeepsWaitingChangesAndFollowsKavitaWhenTheyreCleared() throws {
        let (store, outbox, _) = try stores()
        let made = try store.create(title: "Later", with: 7, account: account, outbox: outbox)
        try store.merge([listed(3, "Mine")], account: account)
        #expect(try store.collections(account: account).map(\.title) == ["Later", "Mine"])
        try outbox.cancelAll(kind: .kavitaCollection)
        try store.merge([listed(3, "Mine")], account: account)
        #expect(try store.collections(account: account).map(\.title) == ["Mine"], "an unsent new collection goes when cleared")
        #expect(try store.seriesRow(collectionId: made.id!, seriesId: 7) == nil)
    }

    @Test func onlyASeriesConfirmsACollection() throws {
        let (store, _, _) = try stores()
        try store.merge([listed(3, "Empty", items: 0), listed(4, "Full", items: 2)], account: account)
        let rows = try store.collections(account: account)
        #expect(rows.first { $0.title == "Empty" }?.confirmed == false)
        #expect(rows.first { $0.title == "Full" }?.confirmed == true)
    }

    @Test func seriesListsAndMembershipKeepWaitingChanges() throws {
        let (store, outbox, _) = try stores()
        try store.merge([listed(3, "Mine", items: 2), listed(4, "Other", items: 1)], account: account)
        let mine = try #require(try store.collections(account: account).first { $0.title == "Mine" }).id!
        let other = try #require(try store.collections(account: account).first { $0.title == "Other" }).id!
        try store.mergeSeries([1, 2], collectionId: mine)
        try store.set(false, seriesId: 1, collectionId: mine, outbox: outbox)
        try store.set(true, seriesId: 9, collectionId: mine, outbox: outbox)
        try store.mergeSeries([1, 2], collectionId: mine)
        #expect(Set(try store.seriesRow(collectionId: mine, seriesId: 1).map { [$0.state] } ?? []) == [.pendingRemove])
        #expect(try store.seriesRow(collectionId: mine, seriesId: 9)?.state == .pendingAdd)
        try store.mergeMembership([4], seriesId: 9, account: account)
        #expect(try store.seriesRow(collectionId: mine, seriesId: 9)?.state == .pendingAdd, "waiting: kept")
        #expect(try store.seriesRow(collectionId: other, seriesId: 9)?.state == .synced)
        try outbox.cancelAll(kind: .kavitaCollection)
        try store.mergeSeries([1, 2], collectionId: mine)
        #expect(try store.seriesRow(collectionId: mine, seriesId: 1)?.state == .synced, "cleared: Kavita's list again")
        #expect(try store.seriesRow(collectionId: mine, seriesId: 9) == nil)
    }

    @Test func theLastSeriesIsJudgedOnTheWholeCollection() throws {
        let (store, outbox, _) = try stores()
        try store.merge([listed(3, "Mine", items: 3)], account: account)
        let mine = try #require(try store.collections(account: account).first).id!
        #expect(try store.seriesCount(collectionId: mine) == 3, "Kavita's count before its series are read")
        try store.mergeSeries([1, 2, 3], collectionId: mine)
        try store.set(false, seriesId: 1, collectionId: mine, outbox: outbox)
        try store.set(false, seriesId: 2, collectionId: mine, outbox: outbox)
        #expect(try store.seriesCount(collectionId: mine) == 1)
        try store.set(true, seriesId: 8, collectionId: mine, outbox: outbox)
        #expect(try store.seriesCount(collectionId: mine) == 2)
    }

    @Test func aCleanedUpNewCollectionIsMadeAgainAtMostTwice() throws {
        let (store, outbox, _) = try stores()
        let made = try store.create(title: "Later", with: 7, account: account, outbox: outbox)
        try store.didCreate(made.id!, serverId: 40)
        #expect(try store.recreate(made.id!, outbox: outbox))
        #expect(try store.collection(made.id!)?.state == .pendingCreate && store.collection(made.id!)?.serverId == nil)
        try store.didCreate(made.id!, serverId: 41)
        #expect(try store.recreate(made.id!, outbox: outbox))
        try store.didCreate(made.id!, serverId: 42)
        #expect(try !store.recreate(made.id!, outbox: outbox), "not a third time")
        // Once a series got in, it's never made again.
        try store.didSend(try #require(try store.seriesRow(collectionId: made.id!, seriesId: 7)))
        #expect(try store.collection(made.id!)?.confirmed == true)
    }

    // MARK: The last series (review cases a–e)

    func collection(_ store: CollectionStore, items: Int) throws -> Int64 {
        try store.merge([listed(3, "Mine", items: items)], account: account)
        return try #require(try store.collections(account: account).first).id!
    }

    @Test func a_threeNeverOpenedOneUnchecked() throws {
        let (store, outbox, _) = try stores()
        let id = try collection(store, items: 3)
        try store.mergeMembership([3], seriesId: 1, account: account)
        #expect(try !store.takingOutEmpties(1, collectionId: id))
        try store.set(false, seriesId: 1, collectionId: id, outbox: outbox)
        #expect(try store.seriesCount(collectionId: id) == 2)
    }

    @Test func b_oneNeverOpenedAsks() throws {
        let (store, _, _) = try stores()
        let id = try collection(store, items: 1)
        try store.mergeMembership([3], seriesId: 1, account: account)
        #expect(try store.takingOutEmpties(1, collectionId: id))
    }

    @Test func c_anotherAddedAndSentThenTheFirstUnchecked() throws {
        let (store, outbox, _) = try stores()
        let id = try collection(store, items: 1)
        try store.mergeMembership([3], seriesId: 1, account: account)
        try store.set(true, seriesId: 2, collectionId: id, outbox: outbox)
        try store.didSend(try #require(try store.seriesRow(collectionId: id, seriesId: 2)))
        #expect(try store.seriesCount(collectionId: id) == 2, "Kavita's count follows the add it took")
        #expect(try !store.takingOutEmpties(1, collectionId: id))
    }

    @Test func d_addedAndTakenOutBeforeSending() throws {
        let (store, outbox, _) = try stores()
        let id = try collection(store, items: 2)
        try store.set(true, seriesId: 5, collectionId: id, outbox: outbox)
        try store.set(false, seriesId: 5, collectionId: id, outbox: outbox)
        #expect(try store.seriesCount(collectionId: id) == 2, "as it was")
    }

    @Test func e_readEarlierThenKavitaSaysFewerAsks() throws {
        let (store, _, _) = try stores()
        let id = try collection(store, items: 3)
        try store.mergeSeries([1, 2, 3], collectionId: id)
        #expect(try !store.takingOutEmpties(1, collectionId: id))
        try store.merge([listed(3, "Mine", items: 1)], account: account)
        #expect(try store.seriesCount(collectionId: id) == nil, "the rows and Kavita's count disagree")
        #expect(try store.takingOutEmpties(1, collectionId: id))
    }

    // MARK: A create whose answer was lost, seen by a refresh first

    @Test func aRefreshAdoptsTheCollectionAWaitingCreateMade() throws {
        let (store, outbox, _) = try stores()
        let made = try store.create(title: "Later", with: 7, account: account, outbox: outbox)
        try store.merge([listed(40, "LATER", items: 0), listed(41, "Other")], account: account)
        let rows = try store.collections(account: account)
        #expect(rows.count == 2, "one row for it, not two")
        let adopted = try #require(try store.collection(made.id!))
        #expect(adopted.serverId == 40 && adopted.state == .synced)
    }
}
