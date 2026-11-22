import Core
import CoreTestSupport
import Foundation
@testable import KavitaKit
import Synchronization
import Testing

/// Collections on Kavita: the handler (made in two steps, safe to run twice) and the refresh.
@Suite struct KavitaCollectionTests {
    let base = URL(string: "https://kavita.example.ts.net")!
    let account = "https://kavita.example.ts.net#reader"

    struct Setup {
        let store: CollectionStore
        let features: ReaderMarkStore
        let outbox: OutboxStore
    }

    func setup() throws -> Setup {
        let database = try AppDatabase.inMemory()
        return Setup(store: CollectionStore(database: database), features: ReaderMarkStore(database: database), outbox: OutboxStore(database: database))
    }

    func client(_ transport: StubTransport) -> KavitaClient {
        KavitaClient(baseURL: base, authKey: "k", http: HTTPClient(transport: transport))
    }

    func send(_ job: CollectionJob, _ setup: Setup, _ transport: StubTransport) async throws {
        let outboxJob = OutboxJob(id: 1, kind: .kavitaCollection, payload: try JSONEncoder().encode(job), state: .inFlight,
                                  nextAttemptAt: .now, createdAt: .now, updatedAt: .now)
        try await KavitaCollectionHandler(store: setup.store, features: setup.features, outbox: setup.outbox) { client(transport) }
            .send(outboxJob, media: [])
    }

    func list(_ items: [(Int, String)]) -> Data {
        let objects = items.map { #"{"id":\#($0.0),"title":"\#($0.1)","summary":null,"promoted":false,"owner":"reader","source":0,"itemCount":1,"ageRating":0}"# }
        return Data(("[" + objects.joined(separator: ",") + "]").utf8)
    }

    func paths(_ transport: StubTransport) -> [String] { transport.requests.map { $0.url!.path() } }

    @Test func aNewCollectionIsMadeEmptyThenFilled() async throws {
        let setup = try setup()
        let made = try setup.store.create(title: "Later", with: 7, account: account, outbox: setup.outbox)
        let created = Mutex(false)
        let transport = StubTransport { request in
            switch request.url!.path() {
            case "/api/Collection": return (200, created.withLock { $0 } ? list([(40, "Later")]) : list([]))
            case "/api/Collection/update-for-series":
                created.withLock { $0 = true }
                return (200, Data())
            default: return (500, Data())
            }
        }
        try await send(CollectionJob(account: account, collectionId: made.id!), setup, transport)
        let body = try transport.requests[1].jsonBody()
        #expect(body["collectionTagId"] as? Int == 0 && (body["seriesIds"] as? [Int])?.isEmpty == true, "made empty")
        #expect(try setup.store.collection(made.id!)?.serverId == 40)
        try await send(CollectionJob(account: account, collectionId: made.id!, seriesId: 7), setup, transport)
        #expect(try transport.requests.last!.jsonBody()["collectionTagId"] as? Int == 40)
        #expect(try setup.store.seriesRow(collectionId: made.id!, seriesId: 7)?.state == .synced)
    }

    @Test func aCreateWhoseAnswerWasLostIsntMadeTwice() async throws {
        let setup = try setup()
        let made = try setup.store.create(title: "Later", with: 7, account: account, outbox: setup.outbox)
        // Kavita already has it (the first try got there): taken, nothing posted.
        let transport = StubTransport(routes: ["/api/Collection": (200, list([(40, "LATER")]))])
        try await send(CollectionJob(account: account, collectionId: made.id!), setup, transport)
        #expect(paths(transport) == ["/api/Collection"])
        #expect(try setup.store.collection(made.id!)?.serverId == 40)
    }

    @Test func aRefusedCreateGoesWithItsSeries() async throws {
        let setup = try setup()
        let made = try setup.store.create(title: "Later", with: 7, account: account, outbox: setup.outbox)
        let transport = StubTransport(routes: ["/api/Collection": (200, list([])), "/api/Collection/update-for-series": (500, Data())])
        await #expect(throws: OutboxPermanentFailure.self) { try await send(CollectionJob(account: account, collectionId: made.id!), setup, transport) }
        #expect(try setup.store.collection(made.id!) == nil)
        #expect(try setup.store.seriesRow(collectionId: made.id!, seriesId: 7) == nil)
        #expect(try setup.outbox.waitingCounts()[.kavitaCollection] == 1, "only the create's own job, which fails")
        // An outage is tried again.
        let other = try self.setup()
        let again = try other.store.create(title: "Later", with: 7, account: account, outbox: other.outbox)
        await #expect(throws: ConnectionError.server(status: 503)) {
            try await send(CollectionJob(account: account, collectionId: again.id!), other,
                           StubTransport(routes: ["/api/Collection": (200, list([])), "/api/Collection/update-for-series": (503, Data())]))
        }
        #expect(try other.store.collection(again.id!) != nil)
    }

    @Test func anAddWaitsForItsCreateAndFinishesWithoutOne() async throws {
        let setup = try setup()
        let made = try setup.store.create(title: "Later", with: 7, account: account, outbox: setup.outbox)
        let transport = StubTransport { _ in (200, Data()) }
        await #expect(throws: ConnectionError.self) { try await send(CollectionJob(account: account, collectionId: made.id!, seriesId: 7), setup, transport) }
        #expect(transport.requests.isEmpty)
        // The create's job cleared: the add can't go anywhere, and finishes.
        try setup.outbox.cancelAll(kind: .kavitaCollection)
        try await send(CollectionJob(account: account, collectionId: made.id!, seriesId: 7), setup, transport)
        #expect(transport.requests.isEmpty)
        #expect(try setup.store.seriesRow(collectionId: made.id!, seriesId: 7) == nil)
    }

    @Test func aSettledAddIsntSentAgain() async throws {
        let setup = try setup()
        try setup.store.merge([.init(serverId: 40, title: "Mine", isOwn: true, owner: "reader", promoted: false, source: 0, itemCount: 1)], account: account)
        let mine = try #require(try setup.store.collections(account: account).first).id!
        try setup.store.set(true, seriesId: 7, collectionId: mine, outbox: setup.outbox)
        let transport = StubTransport { _ in (200, Data()) }
        try await send(CollectionJob(account: account, collectionId: mine, seriesId: 7), setup, transport)
        try await send(CollectionJob(account: account, collectionId: mine, seriesId: 7), setup, transport)
        #expect(transport.requests.count == 1)
    }

    @Test func anEmptyCollectionCleanedUpIsMadeAgainOnlyIfNothingConfirmedIt() async throws {
        let setup = try setup()
        let made = try setup.store.create(title: "Later", with: 7, account: account, outbox: setup.outbox)
        try setup.store.didCreate(made.id!, serverId: 40)
        // Kavita's cleanup took the empty collection before the add.
        let gone = StubTransport(routes: ["/api/Collection/update-for-series": (400, Data("collection-doesnt-exists".utf8)), "/api/Collection": (200, list([]))])
        await #expect(throws: ConnectionError.self) { try await send(CollectionJob(account: account, collectionId: made.id!, seriesId: 7), setup, gone) }
        let row = try #require(try setup.store.collection(made.id!))
        #expect(row.state == .pendingCreate && row.createAttempts == 1, "made again, its create queued")
        #expect(try setup.store.isQueued(CollectionJob(account: account, collectionId: made.id!)))

        // A collection that had a series (deleted on another device): the add goes, nothing's made.
        let other = try self.setup()
        try other.store.merge([.init(serverId: 41, title: "Mine", isOwn: true, owner: "reader", promoted: false, source: 0, itemCount: 2)], account: account)
        let mine = try #require(try other.store.collections(account: account).first).id!
        try other.store.set(true, seriesId: 8, collectionId: mine, outbox: other.outbox)
        try await send(CollectionJob(account: account, collectionId: mine, seriesId: 8), other, gone)
        #expect(try other.store.collection(mine) == nil, "the collection goes here too")
        #expect(try (other.outbox.waitingCounts()[.kavitaCollection] ?? 0) == 0, "no create queued, the add's job gone with it")
    }

    @Test func addsGoBeforeARemoveInTheSameCollection() async throws {
        let setup = try setup()
        try setup.store.merge([.init(serverId: 40, title: "Mine", isOwn: true, owner: "reader", promoted: false, source: 0, itemCount: 1)], account: account)
        let mine = try #require(try setup.store.collections(account: account).first).id!
        try setup.store.mergeSeries([1], collectionId: mine)
        // Offline: the last series out, then another in (queued in that order).
        try setup.store.set(false, seriesId: 1, collectionId: mine, outbox: setup.outbox)
        try setup.store.set(true, seriesId: 2, collectionId: mine, outbox: setup.outbox)
        let transport = StubTransport(routes: ["/api/Collection": (200, list([(40, "Mine")])), "/api/Collection/update-for-series": (200, Data()),
                                               "/api/Collection/update-series": (200, Data())])
        try await send(CollectionJob(account: account, collectionId: mine, seriesId: 1), setup, transport)
        #expect(paths(transport) == ["/api/Collection/update-for-series", "/api/Collection", "/api/Collection/update-series"],
                "the add first, so the remove never empties it")
        #expect(try transport.requests[2].jsonBody()["seriesIdsToRemove"] as? [Int] == [1])
        // The add's own job then has nothing left to do.
        try await send(CollectionJob(account: account, collectionId: mine, seriesId: 2), setup, transport)
        #expect(transport.requests.count == 3)
    }

    @Test func aRefreshIsOneRequestAndTellsOwnFromPromoted() async throws {
        let setup = try setup()
        let all = Data(#"[{"id":1,"title":"Mine","promoted":false,"owner":"reader","source":0,"itemCount":2},{"id":2,"title":"Shared","promoted":true,"owner":"admin","source":0,"itemCount":5},{"id":3,"title":"From MAL","promoted":false,"owner":"reader","source":2,"itemCount":40}]"#.utf8)
        let transport = StubTransport(routes: ["/api/Collection": (200, all)])
        try await KavitaCollectionSync(client: client(transport), store: setup.store, features: setup.features, account: account, username: "reader").refresh()
        #expect(transport.requests.count == 1)
        let rows = try setup.store.collections(account: account)
        #expect(rows.map(\.title) == ["Mine", "Shared", "From MAL"])
        #expect(rows.map(\.isEditable) == [true, false, false])
        // Before Kavita 0.8.0: no collections.
        let old = try self.setup()
        #expect(try await KavitaCollectionSync(client: client(StubTransport(routes: [:])), store: old.store, features: old.features,
                                               account: account, username: "reader").refresh() == false)
        #expect(try !old.features.isAvailable(.collections, account: account))
    }

    @Test func aCreateAfterARefreshAdoptedItSendsNothing() async throws {
        let setup = try setup()
        let made = try setup.store.create(title: "Later", with: 7, account: account, outbox: setup.outbox)
        try setup.store.merge([.init(serverId: 40, title: "Later", isOwn: true, owner: "reader", promoted: false, source: 0, itemCount: 0)], account: account)
        let transport = StubTransport { _ in (200, list([(40, "Later")])) }
        try await send(CollectionJob(account: account, collectionId: made.id!), setup, transport)
        #expect(transport.requests.isEmpty, "found made: no list, no post")
        #expect(try setup.store.collections(account: account).count == 1)
    }

    @Test func takingOutTheLastSeriesTakesTheCollectionOffTheDevice() async throws {
        let setup = try setup()
        try setup.store.merge([.init(serverId: 40, title: "Mine", isOwn: true, owner: "reader", promoted: false, source: 0, itemCount: 1)], account: account)
        let mine = try #require(try setup.store.collections(account: account).first).id!
        try setup.store.mergeSeries([1], collectionId: mine)
        try setup.store.set(false, seriesId: 1, collectionId: mine, outbox: setup.outbox)
        let removed = Mutex(false)
        let transport = StubTransport { request in
            switch request.url!.path() {
            case "/api/Collection": return (200, removed.withLock { $0 } ? list([]) : list([(40, "Mine")]))
            case "/api/Collection/update-series":
                removed.withLock { $0 = true }
                return (200, Data())
            default: return (500, Data())
            }
        }
        try await send(CollectionJob(account: account, collectionId: mine, seriesId: 1), setup, transport)
        #expect(paths(transport) == ["/api/Collection", "/api/Collection/update-series", "/api/Collection"], "one look after, as the count said empty")
        #expect(try setup.store.collection(mine) == nil, "gone here too")

        // Not the last: no look.
        let other = try self.setup()
        try other.store.merge([.init(serverId: 40, title: "Mine", isOwn: true, owner: "reader", promoted: false, source: 0, itemCount: 2)], account: account)
        let two = try #require(try other.store.collections(account: account).first).id!
        try other.store.mergeSeries([1, 2], collectionId: two)
        try other.store.set(false, seriesId: 1, collectionId: two, outbox: other.outbox)
        let quiet = StubTransport(routes: ["/api/Collection": (200, list([(40, "Mine")])), "/api/Collection/update-series": (200, Data())])
        try await send(CollectionJob(account: account, collectionId: two, seriesId: 1), other, quiet)
        #expect(paths(quiet) == ["/api/Collection", "/api/Collection/update-series"])
        #expect(try other.store.collection(two) != nil)
    }

    @Test func aCollectionDeletedElsewhereGoesWithTheAdd() async throws {
        let setup = try setup()
        try setup.store.merge([.init(serverId: 41, title: "Mine", isOwn: true, owner: "reader", promoted: false, source: 0, itemCount: 2)], account: account)
        let mine = try #require(try setup.store.collections(account: account).first).id!
        try setup.store.set(true, seriesId: 8, collectionId: mine, outbox: setup.outbox)
        try setup.store.set(true, seriesId: 9, collectionId: mine, outbox: setup.outbox)
        let gone = StubTransport(routes: ["/api/Collection/update-for-series": (400, Data("collection-doesnt-exists".utf8)), "/api/Collection": (200, list([]))])
        try await send(CollectionJob(account: account, collectionId: mine, seriesId: 8), setup, gone)
        #expect(try setup.store.collection(mine) == nil, "the collection goes, with its rows")
        #expect(try (setup.outbox.waitingCounts()[.kavitaCollection] ?? 0) == 0, "and the other add's job")
    }

    @Test func aCollectionDeletedWhileItsCreateWasOnItsWayIsDeletedOnKavitaToo() async throws {
        let setup = try setup()
        let made = try setup.store.create(title: "Later", with: 7, account: account, outbox: setup.outbox)
        let store = setup.store, outbox = setup.outbox
        let created = Mutex(false)
        let transport = StubTransport { request in
            switch request.url!.path() {
            case "/api/Collection": return (200, created.withLock { $0 } ? list([(40, "Later")]) : list([]))
            case "/api/Collection/update-for-series":
                created.withLock { $0 = true }
                // Deleted here while the create is with Kavita.
                try store.delete(made.id!, outbox: outbox)
                return (200, Data())
            case "/api/Collection/delete-multiple": return (200, Data())
            default: return (500, Data())
            }
        }
        try await send(CollectionJob(account: account, collectionId: made.id!), setup, transport)
        #expect(paths(transport).last == "/api/Collection/delete-multiple", "what it made is deleted")
        #expect(try transport.requests.last!.jsonBody()["collectionIds"] as? [Int] == [40])

        // One it only adopted (never posted) isn't deleted.
        let other = try self.setup()
        let again = try other.store.create(title: "Later", with: 7, account: account, outbox: other.outbox)
        let otherStore = other.store, otherOutbox = other.outbox
        let adopting = StubTransport { request in
            if request.url!.path() == "/api/Collection" {
                try otherStore.delete(again.id!, outbox: otherOutbox)
                return (200, list([(40, "Later")]))
            }
            return (500, Data())
        }
        try await send(CollectionJob(account: account, collectionId: again.id!), other, adopting)
        #expect(paths(adopting) == ["/api/Collection"])
    }

    @Test func theSeriesAreCachedBeforeTheirIdsReachTheGrid() async throws {
        let setup = try setup()
        try setup.store.merge([.init(serverId: 40, title: "Mine", isOwn: true, owner: "reader", promoted: false, source: 0, itemCount: 3)], account: account)
        let mine = try #require(try setup.store.collections(account: account).first)
        let transport = StubTransport(routes: ["/api/Series/v2": (200, try Fixture.data("series-v2.json", in: .module))])
        let store = setup.store
        let idsWhenCached = Mutex<[Int]?>(nil)
        try await KavitaCollectionSync(client: client(transport), store: setup.store, features: setup.features, account: account, username: "reader")
            .series(of: mine) { series in
                #expect(series.count == 3)
                idsWhenCached.withLock { $0 = (try? store.seriesRow(collectionId: mine.id!, seriesId: 9)).map { _ in [9] } ?? [] }
            }
        #expect(idsWhenCached.withLock { $0 } == [], "cached while the ids weren't merged yet")
        #expect(try setup.store.seriesRow(collectionId: mine.id!, seriesId: 9)?.state == .synced)
    }

    @Test func aRemoveThatMayHaveBeenTheLastDropsTheCollectionIfKavitaDeletedIt() async throws {
        let setup = try setup()
        try setup.store.merge([.init(serverId: 40, title: "Mine", isOwn: true, owner: "reader", promoted: false, source: 0, itemCount: 3)], account: account)
        let mine = try #require(try setup.store.collections(account: account).first).id!
        try setup.store.mergeSeries([1, 2, 3], collectionId: mine)
        try setup.store.merge([.init(serverId: 40, title: "Mine", isOwn: true, owner: "reader", promoted: false, source: 0, itemCount: 1)], account: account)
        #expect(try setup.store.takeOut(1, collectionId: mine) == .unknown)
        try setup.store.set(false, seriesId: 1, collectionId: mine, outbox: setup.outbox)
        let removed = Mutex(false)
        let transport = StubTransport { request in
            switch request.url!.path() {
            case "/api/Collection": return (200, removed.withLock { $0 } ? list([]) : list([(40, "Mine")]))
            case "/api/Collection/update-series":
                removed.withLock { $0 = true }
                return (200, Data())
            default: return (500, Data())
            }
        }
        try await send(CollectionJob(account: account, collectionId: mine, seriesId: 1), setup, transport)
        #expect(paths(transport) == ["/api/Collection", "/api/Collection/update-series", "/api/Collection"], "can't tell: one look")
        #expect(try setup.store.collection(mine) == nil, "Kavita deleted it, so it goes here")
    }
}
