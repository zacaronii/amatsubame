import Core
import CoreTestSupport
import Foundation
import KavitaKit
import Synchronization
import Testing

/// Page turns judged by when the page was turned (#204), through the real queue: claimed later
/// than made, and this device's own previous turn told apart from reading elsewhere.
@Suite struct KavitaPageTurnTests {
    let base = URL(string: "https://kavita.example.ts.net")!
    let t0 = Date(timeIntervalSince1970: 1_793_400_000)   // 2026-10-31T00:00:00Z

    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var time: Date
        init(_ time: Date) { self.time = time }
        var now: Date { lock.withLock { time } }
        func set(_ date: Date) { lock.withLock { time = date } }
    }

    struct Setup {
        let clock: Clock
        let outbox: OutboxStore
    }

    func setup() throws -> Setup {
        let clock = Clock(t0)
        return Setup(clock: clock, outbox: OutboxStore(database: try AppDatabase.inMemory()) { clock.now })
    }

    func turn(_ page: Int, at date: Date?, scroll: String? = nil) -> KavitaProgressPayload {
        KavitaProgressPayload(volumeId: 206, chapterId: 206, pageNum: page, seriesId: 4, libraryId: 1, bookScrollId: scroll, madeAt: date)
    }

    func kavita(page: Int, at date: String, scroll: String? = nil) -> Data {
        let scrollJSON = scroll.map { "\"\($0)\"" } ?? "null"
        return Data(#"{"volumeId":206,"chapterId":206,"pageNum":\#(page),"seriesId":4,"libraryId":1,"bookScrollId":\#(scrollJSON),"lastModifiedUtc":"\#(date)"}"#.utf8)
    }

    func send(_ setup: Setup, kavita answer: Data) async throws -> StubTransport {
        let transport = StubTransport(routes: ["/api/Reader/get-progress": (200, answer), "/api/Reader/progress": (200, Data()),
                                               "/api/Reader/mark-multiple-read": (200, Data())])
        let handler = KavitaProgressHandler(outbox: setup.outbox) { KavitaClient(baseURL: base, authKey: "k", http: HTTPClient(transport: transport)) }
        let claimed = try #require(try setup.outbox.claimDueJobs(kinds: [.kavitaProgress]).first)
        try await handler.send(claimed.job, media: [])
        try setup.outbox.markSent(claimed.job.id!)
        return transport
    }

    func paths(_ transport: StubTransport) -> [String] { transport.requests.map { $0.url!.path() } }

    @Test func aTurnSentLateIsJudgedByWhenItWasTurned() async throws {
        let setup = try setup()
        try setup.outbox.enqueue(turn(5, at: t0), kind: .kavitaProgress, coalesceKey: "kavita.chapter.206")
        setup.clock.set(t0.addingTimeInterval(2 * 86_400))   // sent two days later
        let transport = try await send(setup, kavita: kavita(page: 9, at: "2026-11-01T00:00:00"))   // read elsewhere a day after
        #expect(paths(transport) == ["/api/Reader/get-progress"], "the older page isn't sent over newer reading")
    }

    @Test func thisDevicesOwnTurnOnItsWayDoesntCountAsElsewhere() async throws {
        let setup = try setup()
        // Page 5 turned and sent; Kavita dates it when it arrives, after page 6 was turned here.
        try setup.outbox.enqueue(turn(5, at: t0, scroll: "//p[1]"), kind: .kavitaProgress, coalesceKey: "kavita.chapter.206")
        _ = try await send(setup, kavita: kavita(page: 0, at: "2026-10-30T00:00:00"))
        setup.clock.set(t0.addingTimeInterval(10))
        try setup.outbox.enqueue(turn(6, at: t0.addingTimeInterval(10)), kind: .kavitaProgress, coalesceKey: "kavita.chapter.206")
        let transport = try await send(setup, kavita: kavita(page: 5, at: "2026-10-31T00:00:30", scroll: "//p[1]"))
        #expect(paths(transport) == ["/api/Reader/get-progress", "/api/Reader/progress"], "page 6 goes: Kavita holds this device's page 5")
        #expect(try transport.requests[1].jsonBody()["pageNum"] as? Int == 6)
    }

    @Test func readingElsewhereAfterThisDevicesLastSendStillWins() async throws {
        let setup = try setup()
        try setup.outbox.enqueue(turn(5, at: t0), kind: .kavitaProgress, coalesceKey: "kavita.chapter.206")
        _ = try await send(setup, kavita: kavita(page: 0, at: "2026-10-30T00:00:00"))
        try setup.outbox.enqueue(turn(6, at: t0.addingTimeInterval(10)), kind: .kavitaProgress, coalesceKey: "kavita.chapter.206")
        let transport = try await send(setup, kavita: kavita(page: 12, at: "2026-10-31T01:00:00"))
        #expect(paths(transport) == ["/api/Reader/get-progress"], "Kavita moved past what this device sent")
    }

    @Test func aTurnQueuedByAnOlderBuildIsJudgedAsBefore() async throws {
        let setup = try setup()
        try setup.outbox.enqueue(turn(5, at: nil), kind: .kavitaProgress, coalesceKey: "kavita.chapter.206")
        setup.clock.set(t0.addingTimeInterval(2 * 86_400))
        let transport = try await send(setup, kavita: kavita(page: 9, at: "2026-11-01T00:00:00"))
        #expect(paths(transport) == ["/api/Reader/get-progress", "/api/Reader/progress"], "no madeAt: judged by when it's sent")
    }

    @Test func theTurnsTimeIsNeverSentToKavita() async throws {
        let setup = try setup()
        try setup.outbox.enqueue(turn(5, at: t0), kind: .kavitaProgress, coalesceKey: "kavita.chapter.206")
        let transport = try await send(setup, kavita: kavita(page: 0, at: "2026-10-30T00:00:00"))
        #expect(try transport.requests[1].jsonBody()["madeAt"] == nil)
        #expect(try transport.requests[1].jsonBody()["pageNum"] as? Int == 5)
    }

    @Test func aMarkMadeWhileThisDevicesTurnWasOnItsWayIsSent() async throws {
        let setup = try setup()
        try setup.outbox.enqueue(turn(5, at: t0), kind: .kavitaProgress, coalesceKey: "kavita.chapter.206")
        _ = try await send(setup, kavita: kavita(page: 0, at: "2026-10-30T00:00:00"))
        let mark = KavitaReadMarkPayload(mark: .read, seriesId: 4, chapterId: 206, account: nil, madeAt: t0.addingTimeInterval(10))
        try setup.outbox.enqueue(mark, kind: .kavitaProgress, coalesceKey: mark.coalesceKey)
        let transport = try await send(setup, kavita: kavita(page: 5, at: "2026-10-31T00:00:30"))
        #expect(paths(transport) == ["/api/Reader/get-progress", "/api/Reader/mark-multiple-read"])
    }
}
