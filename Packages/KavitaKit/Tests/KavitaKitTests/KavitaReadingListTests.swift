import Core
import CoreTestSupport
import Foundation
import GRDB
@testable import KavitaKit
import Synchronization
import Testing

/// Reading lists on Kavita: the handler (moves by anchor, creates safe to run twice, lists Kavita
/// cleaned up) and the refresh.
@Suite struct KavitaReadingListTests {
    let base = URL(string: "https://kavita.example.ts.net")!
    let account = "https://kavita.example.ts.net#reader"

    struct Setup {
        let store: ReadingListStore
        let features: ReaderMarkStore
        let outbox: OutboxStore
    }

    func setup() throws -> Setup {
        let database = try AppDatabase.inMemory()
        return Setup(store: ReadingListStore(database: database), features: ReaderMarkStore(database: database), outbox: OutboxStore(database: database))
    }

    func client(_ transport: StubTransport) -> KavitaClient {
        KavitaClient(baseURL: base, authKey: "k", http: HTTPClient(transport: transport))
    }

    func send(_ job: ReadingListJob, _ setup: Setup, _ transport: StubTransport) async throws {
        let queued = try await setup.store.database.reader.read { try OutboxJob.filter(Column("coalesceKey") == job.coalesceKey).fetchOne($0) }
        let outboxJob = OutboxJob(id: queued?.id ?? 1, kind: .kavitaReadingList, payload: try JSONEncoder().encode(job), state: .inFlight,
                                  nextAttemptAt: .now, createdAt: .now, updatedAt: .now)
        try await KavitaReadingListHandler(store: setup.store, features: setup.features, outbox: setup.outbox) { client(transport) }
            .send(outboxJob, media: [])
        // Sent: the worker deletes the job.
        if let id = queued?.id { _ = try await setup.store.database.writer.write { try OutboxJob.deleteOne($0, key: id) } }
    }

    func chapter(_ id: Int) -> ReadingListChapter {
        ReadingListChapter(chapterId: id, seriesId: id * 10, volumeId: id * 100, libraryId: 1, format: 1, seriesName: "Series", title: "Vol. \(id)")
    }

    func itemsJSON(_ chapters: [Int]) -> Data {
        let objects = chapters.enumerated().map { #"{"id":\#(100 + $1),"order":\#($0),"chapterId":\#($1),"seriesId":\#($1 * 10),"volumeId":\#($1 * 100),"libraryId":1,"seriesFormat":1,"seriesName":"Series","title":"Vol. \#($1)"}"# }
        return Data(("[" + objects.joined(separator: ",") + "]").utf8)
    }

    func listsJSON(_ lists: [(Int, String, Int)]) -> Data {
        Data(("[" + lists.map { #"{"id":\#($0.0),"title":"\#($0.1)","promoted":false,"ownerUserName":"reader","itemCount":\#($0.2)}"# }.joined(separator: ",") + "]").utf8)
    }

    func paths(_ transport: StubTransport) -> [String] { transport.requests.map { $0.url!.path() } }

    /// A list (Kavita id 9) with items 1–4, read.
    func abcd(_ setup: Setup) throws -> Int64 {
        try setup.store.merge([.init(serverId: 9, title: "Mine", isOwn: true, owner: "reader", promoted: false, isSynced: false, itemCount: 4)], account: account)
        let id = try #require(try setup.store.lists(account: account).first).id!
        try setup.store.mergeItems((1...4).map { .init(serverItemId: 100 + $0, chapter: chapter($0)) }, listId: id)
        return id
    }

    func moveId(_ setup: Setup) throws -> Int64 {
        try #require(try setup.store.database.reader.read { try ReadingListMoveRow.order(Column("id").desc).fetchOne($0)?.id })
    }

    @Test func movesSendThePositionKavitaExpectsBothWays() async throws {
        let setup = try setup()
        let id = try abcd(setup)
        // Forward: 1 after 3 → 2 3 1 4; Kavita takes 1 out (2 3 4) and puts it at 2.
        try setup.store.move(1, after: 3, listId: id, outbox: setup.outbox)
        let transport = StubTransport { _ in (200, Data()) }
        try await send(ReadingListJob(account: account, listId: id, moveId: try moveId(setup)), setup, transport)
        #expect(try transport.requests.last!.jsonBody()["toPosition"] as? Int == 2)
        #expect(try transport.requests.last!.jsonBody()["readingListItemId"] as? Int == 101)
        // Backward: 4 first → 4 2 3 1; position 0. No read: the order is known from the last move.
        try setup.store.move(4, after: nil, listId: id, outbox: setup.outbox)
        try await send(ReadingListJob(account: account, listId: id, moveId: try moveId(setup)), setup, transport)
        #expect(try transport.requests.last!.jsonBody()["toPosition"] as? Int == 0)
        #expect(paths(transport) == ["/api/ReadingList/update-position", "/api/ReadingList/update-position"], "N moves: no read while the items are fresh")
        #expect(try setup.store.items(listId: id).map(\.chapterId) == [4, 2, 3, 1])
    }

    @Test func aMoveAlreadyInPlaceSendsNothing() async throws {
        let setup = try setup()
        let id = try abcd(setup)
        try setup.store.move(2, after: 1, listId: id, outbox: setup.outbox)
        let transport = StubTransport { _ in (200, Data()) }
        try await send(ReadingListJob(account: account, listId: id, moveId: try moveId(setup)), setup, transport)
        #expect(transport.requests.isEmpty)
    }

    @Test func staleItemsAreReadOnceAndAGoneAnchorFallsBack() async throws {
        let setup = try setup()
        let id = try abcd(setup)
        try setup.store.move(4, after: 2, listId: id, outbox: setup.outbox)  // chain [2, 1]
        _ = try await setup.store.database.writer.write { try $0.execute(sql: "UPDATE kavitaReadingList SET itemsStale = 1") }
        // Kavita no longer has 2: 4 goes after 1.
        let transport = StubTransport { request in
            request.url!.path() == "/api/ReadingList/items" ? (200, itemsJSON([1, 3, 4])) : (200, Data())
        }
        try await send(ReadingListJob(account: account, listId: id, moveId: try moveId(setup)), setup, transport)
        #expect(paths(transport) == ["/api/ReadingList/items", "/api/ReadingList/update-position"])
        #expect(try transport.requests.last!.jsonBody()["toPosition"] as? Int == 1)
    }

    @Test func aMoveWaitsForItsUnsentAddAndEndsWithoutIt() async throws {
        let setup = try setup()
        let id = try abcd(setup)
        try setup.store.set(true, chapter: chapter(7), listId: id, outbox: setup.outbox)
        try setup.store.move(7, after: nil, listId: id, outbox: setup.outbox)
        let transport = StubTransport { _ in (200, Data()) }
        await #expect(throws: ConnectionError.self) { try await send(ReadingListJob(account: account, listId: id, moveId: try moveId(setup)), setup, transport) }
        try setup.outbox.cancelAll(kind: .kavitaReadingList)
        try await send(ReadingListJob(account: account, listId: id, moveId: try moveId(setup)), setup, transport)
        #expect(transport.requests.isEmpty)
    }

    @Test func aRemoveFindsTheItemByChapterAndOneGoneEndsQuietly() async throws {
        let setup = try setup()
        let id = try abcd(setup)
        _ = try await setup.store.database.writer.write { try $0.execute(sql: "UPDATE kavitaReadingList SET itemsStale = 1") }
        try setup.store.set(false, chapter: chapter(3), listId: id, outbox: setup.outbox)
        let transport = StubTransport { request in
            request.url!.path() == "/api/ReadingList/items" ? (200, itemsJSON([1, 2, 3, 4])) : (200, Data())
        }
        try await send(ReadingListJob(account: account, listId: id, chapterId: 3), setup, transport)
        #expect(try transport.requests.last!.jsonBody()["readingListItemId"] as? Int == 103)
        // Already gone on Kavita: nothing sent, settled.
        try setup.store.set(false, chapter: chapter(4), listId: id, outbox: setup.outbox)
        _ = try await setup.store.database.writer.write { try $0.execute(sql: "UPDATE kavitaReadingList SET itemsStale = 1") }
        let gone = StubTransport { request in request.url!.path() == "/api/ReadingList/items" ? (200, itemsJSON([1, 2])) : (500, Data()) }
        try await send(ReadingListJob(account: account, listId: id, chapterId: 4), setup, gone)
        #expect(paths(gone) == ["/api/ReadingList/items"])
        #expect(try setup.store.item(listId: id, chapterId: 4)?.isIn == false)
    }

    @Test func aCreateIsSafeToRunTwice() async throws {
        let setup = try setup()
        let made = try setup.store.create(title: "Later", with: chapter(1), account: account, outbox: setup.outbox)
        // Already there (a lost answer): taken, nothing posted.
        let there = StubTransport(routes: ["/api/ReadingList/lists": (200, listsJSON([(40, "LATER", 0)]))])
        try await send(ReadingListJob(account: account, listId: made.id!), setup, there)
        #expect(paths(there) == ["/api/ReadingList/lists"])
        #expect(try setup.store.list(made.id!)?.serverId == 40)

        // Refused for its title but not found: a permanent failure naming it, its rows gone.
        let other = try self.setup()
        let again = try other.store.create(title: "Later", with: chapter(1), account: account, outbox: other.outbox)
        let refused = StubTransport(routes: ["/api/ReadingList/lists": (200, listsJSON([])), "/api/ReadingList/create": (400, Data("A reading list of this name already exists".utf8))])
        await #expect(throws: OutboxPermanentFailure.self) { try await send(ReadingListJob(account: account, listId: again.id!), other, refused) }
        #expect(try other.store.list(again.id!) == nil)
    }

    @Test func aListDeletedWhileItsCreateWasOnItsWayIsDeletedOnKavita() async throws {
        let setup = try setup()
        let made = try setup.store.create(title: "Later", with: chapter(1), account: account, outbox: setup.outbox)
        let store = setup.store, outbox = setup.outbox
        let transport = StubTransport { request in
            switch request.url!.path() {
            case "/api/ReadingList/lists": return (200, listsJSON([]))
            case "/api/ReadingList/create":
                try store.delete(made.id!, outbox: outbox)
                return (200, Data(#"{"id":41,"title":"Later"}"#.utf8))
            default: return (200, Data())
            }
        }
        try await send(ReadingListJob(account: account, listId: made.id!), setup, transport)
        #expect(transport.requests.last!.httpMethod == "DELETE")
        #expect(transport.requests.last!.url!.query()?.contains("readingListId=41") == true)
    }

    @Test func anEmptiedListCleanedUpIsMadeAgainOneWithItemsWasDeletedElsewhere() async throws {
        let setup = try setup()
        try setup.store.merge([.init(serverId: 9, title: "Emptied", isOwn: true, owner: "reader", promoted: false, isSynced: false, itemCount: 0)], account: account)
        let emptied = try #require(try setup.store.lists(account: account).first).id!
        try setup.store.set(true, chapter: chapter(5), listId: emptied, outbox: setup.outbox)
        let gone = StubTransport { request in
            request.url!.path() == "/api/ReadingList/items" ? (404, Data()) : (400, Data("permission".utf8))
        }
        await #expect(throws: ConnectionError.self) { try await send(ReadingListJob(account: account, listId: emptied, chapterId: 5), setup, gone) }
        #expect(try setup.store.list(emptied)?.state == .pendingCreate, "made again, with its add")
        #expect(try setup.store.item(listId: emptied, chapterId: 5)?.state == .pendingAdd)

        let other = try self.setup()
        try other.store.merge([.init(serverId: 10, title: "Full", isOwn: true, owner: "reader", promoted: false, isSynced: false, itemCount: 3)], account: account)
        let full = try #require(try other.store.lists(account: account).first).id!
        try other.store.set(true, chapter: chapter(6), listId: full, outbox: other.outbox)
        try await send(ReadingListJob(account: account, listId: full, chapterId: 6), other, gone)
        #expect(try other.store.list(full) == nil, "deleted elsewhere: it goes here, with the add")
    }

    /// The first of two moves backs off: the second waits instead of overtaking it.
    @Test func aMoveWaitsForAnEarlierMoveBackingOff() async throws {
        let setup = try setup()
        let id = try abcd(setup)
        try setup.store.move(1, after: 4, listId: id, outbox: setup.outbox)   // B C D A
        let first = try moveId(setup)
        try setup.store.move(2, after: 1, listId: id, outbox: setup.outbox)   // C D A B
        let second = try moveId(setup)
        let transport = StubTransport { _ in (200, Data()) }
        await #expect(throws: ConnectionError.self) { try await send(ReadingListJob(account: account, listId: id, moveId: second), setup, transport) }
        #expect(transport.requests.isEmpty, "nothing sent while the first is still to go")
        let firstJob = ReadingListJob(account: account, listId: id, moveId: first)
        try await send(firstJob, setup, transport)
        _ = try await setup.store.database.writer.write { try OutboxJob.filter(Column("coalesceKey") == firstJob.coalesceKey).deleteAll($0) }
        try await send(ReadingListJob(account: account, listId: id, moveId: second), setup, transport)
        #expect(try transport.requests.map { try $0.jsonBody()["toPosition"] as? Int } == [3, 3])
        #expect(try setup.store.kavitaItems(listId: id).map(\.chapterId) == [3, 4, 1, 2], "Kavita ends as the device shows")
    }

    /// An add sent while a read was on its way: the read doesn't count as fresh, so a remove of it
    /// reads again and finds its Kavita id.
    @Test func aRemoveOfAnAddTheReadMissedFindsItsId() async throws {
        let setup = try setup()
        let id = try abcd(setup)
        let readAt = Date(timeIntervalSinceNow: -5)
        try setup.store.set(true, chapter: chapter(7), listId: id, outbox: setup.outbox)
        try setup.store.didSend(try #require(try setup.store.item(listId: id, chapterId: 7)))
        try setup.store.mergeItems((1...4).map { .init(serverItemId: 100 + $0, chapter: chapter($0)) }, listId: id, listedAt: readAt)
        #expect(try !setup.store.itemsAreFresh(id))
        #expect(try setup.store.list(id)?.kavitaItemCount == 5, "the read's count isn't taken")
        try setup.store.set(false, chapter: chapter(7), listId: id, outbox: setup.outbox)
        let transport = StubTransport { request in
            request.url!.path() == "/api/ReadingList/items" ? (200, itemsJSON([1, 2, 3, 4, 7])) : (200, Data())
        }
        try await send(ReadingListJob(account: account, listId: id, chapterId: 7), setup, transport)
        #expect(paths(transport) == ["/api/ReadingList/items", "/api/ReadingList/delete-item"])
        #expect(try transport.requests.last!.jsonBody()["readingListItemId"] as? Int == 107)
    }

    /// A refresh that no longer lists an emptied list with an add waiting keeps it; the add's job
    /// then makes it again.
    @Test func aRefreshLeavesAnEmptiedListWithAWaitingAddToTheHandler() async throws {
        let setup = try setup()
        try setup.store.merge([.init(serverId: 9, title: "Emptied", isOwn: true, owner: "reader", promoted: false, isSynced: false, itemCount: 0)], account: account)
        let emptied = try #require(try setup.store.lists(account: account).first).id!
        try setup.store.set(true, chapter: chapter(5), listId: emptied, outbox: setup.outbox)
        try setup.store.merge([], account: account)
        #expect(try setup.store.list(emptied) != nil, "kept for the add's job")
        let gone = StubTransport { request in
            request.url!.path() == "/api/ReadingList/items" ? (404, Data()) : (400, Data("permission".utf8))
        }
        await #expect(throws: ConnectionError.self) { try await send(ReadingListJob(account: account, listId: emptied, chapterId: 5), setup, gone) }
        #expect(try setup.store.list(emptied)?.state == .pendingCreate, "made again")
        #expect(try setup.store.item(listId: emptied, chapterId: 5)?.state == .pendingAdd)
        // Without an add waiting, a list Kavita no longer lists goes.
        try setup.outbox.cancelAll(kind: .kavitaReadingList)
        try setup.store.merge([.init(serverId: 9, title: "Emptied", isOwn: true, owner: "reader", promoted: false, isSynced: false, itemCount: 0)], account: account)
        try setup.store.merge([], account: account)
        #expect(try setup.store.lists(account: account).isEmpty)
    }

    @Test func aSeriesFetchedForAnItemIsCachedWithKavitasBytes() async throws {
        let database = try AppDatabase.inMemory()
        let repository = KavitaLibraryRepository(database: database)
        let transport = StubTransport(routes: [
            "/api/Library/libraries": (200, try Fixture.data("libraries.json", in: .module)),
            "/api/Series/34": (200, try Fixture.data("series.json", in: .module)),
        ])
        _ = try await repository.refreshLibraries(using: client(transport))
        #expect(try await repository.rememberSeries(id: 34, using: client(transport)))
        let cached = try #require(try repository.cachedSeries(id: 34))
        #expect(cached.localizedName != nil, "decoded from what Kavita sent, not the columns")
        #expect(cached.created != nil)
    }

    @Test func aRefreshReadsEveryPageAndTellsOwnWithoutOwnerNames() async throws {
        let setup = try setup()
        let pages = Mutex(0)
        let transport = StubTransport { request in
            let page = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "pageNumber" }?.value
            let promoted = request.url!.query()?.contains("includePromoted=true") == true
            if promoted { pages.withLock { $0 += 1 } }
            // Kavita before 0.8.8: no owner names; page 1 full, page 2 short.
            let first = #"[{"id":1,"title":"Mine","promoted":false},{"id":2,"title":"Shared","promoted":true}]"#
            if !promoted { return (200, Data(#"[{"id":1,"title":"Mine","promoted":false}]"#.utf8)) }
            return (200, Data((page == "1" ? first : "[]").utf8))
        }
        try await KavitaReadingListSync(client: client(transport), store: setup.store, features: setup.features, account: account, username: "reader")
            .refresh()
        #expect(pages.withLock { $0 } >= 1)
        let rows = try setup.store.lists(account: account)
        #expect(rows.map(\.title) == ["Mine", "Shared"])
        #expect(rows.map(\.isEditable) == [true, false])
        #expect(rows.first?.kavitaItemCount == nil, "no count before 0.8.4")
    }
}
