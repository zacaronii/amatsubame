import Core
import CoreTestSupport
import Foundation
@testable import KavitaKit
import Testing

/// Want to Read on Kavita: the paged list, the handler and the refresh.
@Suite struct KavitaWantToReadTests {
    let base = URL(string: "https://kavita.example.ts.net")!
    let account = "https://kavita.example.ts.net#reader"

    struct Setup {
        let store: WantToReadStore
        let features: ReaderMarkStore
        let outbox: OutboxStore
    }

    func setup() throws -> Setup {
        let database = try AppDatabase.inMemory()
        return Setup(store: WantToReadStore(database: database), features: ReaderMarkStore(database: database), outbox: OutboxStore(database: database))
    }

    func client(_ transport: StubTransport) -> KavitaClient {
        KavitaClient(baseURL: base, authKey: "k", http: HTTPClient(transport: transport))
    }

    func send(_ seriesId: Int, _ setup: Setup, _ transport: StubTransport, signedIn: String? = nil) async throws {
        let job = OutboxJob(id: 1, kind: .kavitaWantToRead, payload: try JSONEncoder().encode(WantToReadJob(account: account, seriesId: seriesId)),
                            state: .inFlight, nextAttemptAt: .now, createdAt: .now, updatedAt: .now)
        try await KavitaWantToReadHandler(store: setup.store, features: setup.features, account: { signedIn }) { client(transport) }
            .send(job, media: [])
    }

    @Test func theWholeListIsReadPageByPage() async throws {
        let list = try Fixture.data("series-v2.json", in: .module)
        let transport = StubTransport { request in
            let page = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "pageNumber" }?.value
            return page == "1" ? (200, list) : (200, Data("[]".utf8))
        }
        let series = try await client(transport).wantToRead(pageSize: 3)
        #expect(series.map(\.0.id) == [9, 11, 10])
        #expect(transport.requests.count == 2, "a full page asks for the next")
        _ = try await client(transport).wantToReadPage(1, pageSize: 1)
        #expect(transport.requests.count == 3, "a single page is one request")
        #expect(try transport.requests[0].jsonBody()["statements"] as? [Any] != nil)
    }

    @Test func addingAndRemovingSendTheRowsState() async throws {
        let setup = try setup()
        try setup.store.set(true, seriesId: 7, account: account, outbox: setup.outbox)
        let transport = StubTransport { _ in (200, Data()) }
        try await send(7, setup, transport)
        #expect(transport.requests.map { $0.url!.path() } == ["/api/want-to-read/add-series"])
        #expect(try transport.requests[0].jsonBody()["seriesIds"] as? [Int] == [7])
        #expect(try setup.store.row(account: account, seriesId: 7)?.state == .synced)

        try setup.store.set(false, seriesId: 7, account: account, outbox: setup.outbox)
        try await send(7, setup, transport)
        #expect(transport.requests.last?.url?.path() == "/api/want-to-read/remove-series")
        #expect(try setup.store.isWanted(account: account, seriesId: 7) == false)
        #expect(try setup.store.row(account: account, seriesId: 7)?.state == .removed)
    }

    @Test func aJobRunAgainAfterTheAppDiedSendsNothing() async throws {
        let setup = try setup()
        try setup.store.merge([7], account: account)
        try setup.store.set(false, seriesId: 7, account: account, outbox: setup.outbox)
        let transport = StubTransport { _ in (200, Data()) }
        try await send(7, setup, transport)
        // The app died before the job was marked sent: on launch it's pending again, and runs.
        try await send(7, setup, transport)
        #expect(transport.requests.count == 1, "sent once")
        #expect(try !setup.store.isWanted(account: account, seriesId: 7))
    }

    @Test func anotherAccountsToggleWaits() async throws {
        let setup = try setup()
        try setup.store.set(true, seriesId: 7, account: account, outbox: setup.outbox)
        let transport = StubTransport { _ in (200, Data()) }
        await #expect(throws: ConnectionError.self) { try await send(7, setup, transport, signedIn: "https://other.example#someone") }
        #expect(transport.requests.isEmpty)
        #expect(try setup.store.row(account: account, seriesId: 7)?.state == .pendingAdd)
    }

    @Test func aServerWithoutWantToReadStopsBeingOfferedIt() async throws {
        let setup = try setup()
        try setup.store.set(true, seriesId: 7, account: account, outbox: setup.outbox)
        try await send(7, setup, StubTransport(routes: [:]))
        #expect(try !setup.features.isAvailable(.wantToRead, account: account))
        #expect(try setup.store.row(account: account, seriesId: 7) == nil, "the unsent toggle goes")

        // One 404 with the list answering is that toggle's failure only; a list that can't be
        // reached tries again.
        let other = try self.setup()
        try other.store.set(true, seriesId: 8, account: account, outbox: other.outbox)
        await #expect(throws: OutboxPermanentFailure.self) {
            try await send(8, other, StubTransport(routes: ["/api/want-to-read/add-series": (404, Data()), "/api/want-to-read/v2": (200, Data("[]".utf8))]))
        }
        await #expect(throws: ConnectionError.server(status: 503)) {
            try await send(8, other, StubTransport(routes: ["/api/want-to-read/add-series": (404, Data()), "/api/want-to-read/v2": (503, Data())]))
        }
        #expect(try other.features.isAvailable(.wantToRead, account: account))
    }

    @Test func aRefreshKeepsUnsentTogglesAndTheSeriesPageAsks() async throws {
        let setup = try setup()
        try setup.store.merge([11], account: account)
        try setup.store.set(false, seriesId: 11, account: account, outbox: setup.outbox)
        let transport = StubTransport(routes: [
            "/api/want-to-read/v2": (200, try Fixture.data("series-v2.json", in: .module)),
            "/api/want-to-read": (200, Data("true".utf8)),
        ])
        let sync = KavitaWantToReadSync(client: client(transport), store: setup.store, features: setup.features, account: account)
        let listed = try await sync.refresh()
        #expect(listed?.count == 3)
        let wanted = try setup.store.wanted(account: account)
        #expect(wanted == [9, 10], "11's unsent removal stays (got \(wanted))")
        try await sync.check(seriesId: 12)
        #expect(try setup.store.isWanted(account: account, seriesId: 12))

        let old = try self.setup()
        let none = try await KavitaWantToReadSync(client: client(StubTransport(routes: [:])), store: old.store, features: old.features, account: account).refresh()
        #expect(none == nil)
        #expect(try !old.features.isAvailable(.wantToRead, account: account))
    }
}
