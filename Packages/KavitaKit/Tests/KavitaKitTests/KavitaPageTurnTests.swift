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
                                               "/api/Reader/mark-multiple-read": (200, Data()), "/api/Reader/mark-multiple-unread": (200, Data()),
                                               "/api/Series/volumes": (200, Data("[]".utf8)), "/api/Reader/mark-read": (200, Data())])
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

    // MARK: After a mark from this device

    func mark(_ mark: KavitaReadMarkPayload.Mark, at date: Date, pages: Int? = 20, series: Bool = false) -> KavitaReadMarkPayload {
        KavitaReadMarkPayload(mark: mark, seriesId: 4, chapterId: series ? nil : 206, account: nil, madeAt: date,
                              chapterPages: pages.map { [206: $0] })
    }

    /// Sends a read mark of the chapter (or series) first, as this device did.
    func sentReadMark(_ setup: Setup, pages: Int? = 20, series: Bool = false) async throws {
        let read = mark(.read, at: t0, pages: pages, series: series)
        try setup.outbox.enqueue(read, kind: .kavitaProgress, coalesceKey: read.coalesceKey)
        _ = try await send(setup, kavita: kavita(page: 0, at: "2026-10-30T00:00:00"))
    }

    @Test func anUnreadMadeBeforeThisDevicesReadArrivedIsSent() async throws {
        let setup = try setup()
        try await sentReadMark(setup)
        let unread = mark(.unread, at: t0.addingTimeInterval(5))
        try setup.outbox.enqueue(unread, kind: .kavitaProgress, coalesceKey: unread.coalesceKey)
        let transport = try await send(setup, kavita: kavita(page: 20, at: "2026-10-31T00:00:30"))
        #expect(paths(transport) == ["/api/Reader/get-progress", "/api/Reader/mark-multiple-unread"], "Kavita holds this device's read")
    }

    @Test func aTurnMadeBeforeThisDevicesMarkArrivedIsSent() async throws {
        let setup = try setup()
        try await sentReadMark(setup)
        try setup.outbox.enqueue(turn(3, at: t0.addingTimeInterval(5)), kind: .kavitaProgress, coalesceKey: "kavita.chapter.206")
        let transport = try await send(setup, kavita: kavita(page: 20, at: "2026-10-31T00:00:30"))
        #expect(paths(transport) == ["/api/Reader/get-progress", "/api/Reader/progress"])
    }

    @Test func aTurnMadeBeforeThisDevicesSeriesMarkArrivedIsSent() async throws {
        let setup = try setup()
        try await sentReadMark(setup, series: true)
        try setup.outbox.enqueue(turn(3, at: t0.addingTimeInterval(5)), kind: .kavitaProgress, coalesceKey: "kavita.chapter.206")
        let transport = try await send(setup, kavita: kavita(page: 20, at: "2026-10-31T00:00:30"))
        #expect(paths(transport) == ["/api/Reader/get-progress", "/api/Reader/progress"], "the series' key is looked up too")
    }

    @Test func readingElsewhereAfterThisDevicesReadMarkStillWins() async throws {
        let setup = try setup()
        try await sentReadMark(setup)
        try setup.outbox.enqueue(turn(15, at: t0.addingTimeInterval(5)), kind: .kavitaProgress, coalesceKey: "kavita.chapter.206")
        let transport = try await send(setup, kavita: kavita(page: 3, at: "2026-10-31T01:00:00"))   // re-read elsewhere to page 3
        #expect(paths(transport) == ["/api/Reader/get-progress"], "Kavita holds less than a read mark leaves: not this device's")
    }

    @Test func aReadMarkWithoutItsPagesNeverCountsAsOwn() async throws {
        let setup = try setup()
        try await sentReadMark(setup, pages: nil)
        try setup.outbox.enqueue(turn(3, at: t0.addingTimeInterval(5)), kind: .kavitaProgress, coalesceKey: "kavita.chapter.206")
        let transport = try await send(setup, kavita: kavita(page: 20, at: "2026-10-31T00:00:30"))
        #expect(paths(transport) == ["/api/Reader/get-progress"], "an older build's mark: judged by dates alone")
    }

    // MARK: At a reader's start (the sender's own check)

    func server(page: Int, at seconds: TimeInterval, scroll: String? = nil) -> KavitaServerProgress {
        KavitaServerProgress(chapterId: 206, pageNum: page, bookScrollId: scroll, lastModifiedUtc: t0.addingTimeInterval(seconds))
    }

    @Test func aStuckTurnOverNewerReadingElsewhereDoesntHoldTheStart() throws {
        let setup = try setup()
        try setup.outbox.enqueue(turn(20, at: t0), kind: .kavitaProgress, coalesceKey: "kavita.chapter.206")
        let still = try KavitaProgressCheck.queuedChangeStillGoes(chapterId: 206, seriesId: 4, server: server(page: 60, at: 3600), outbox: setup.outbox)
        #expect(!still, "the sender will drop it: open at Kavita's 60")
    }

    @Test func aQueuedTurnBehindThisDevicesOwnSendHoldsTheStart() async throws {
        let setup = try setup()
        try setup.outbox.enqueue(turn(5, at: t0), kind: .kavitaProgress, coalesceKey: "kavita.chapter.206")
        _ = try await send(setup, kavita: kavita(page: 0, at: "2026-10-30T00:00:00"))
        try setup.outbox.enqueue(turn(6, at: t0.addingTimeInterval(10)), kind: .kavitaProgress, coalesceKey: "kavita.chapter.206")
        // Kavita dated this device's page 5 after page 6 was turned (or the clock is behind).
        let still = try KavitaProgressCheck.queuedChangeStillGoes(chapterId: 206, seriesId: 4, server: server(page: 5, at: 30), outbox: setup.outbox)
        #expect(still, "it will be sent: open at this device's place")
    }

    @Test func aWaitingSeriesMarkOverNewerReadingElsewhereDoesntHoldTheStart() throws {
        let setup = try setup()
        let unread = mark(.unread, at: t0, series: true)
        try setup.outbox.enqueue(unread, kind: .kavitaProgress, coalesceKey: unread.coalesceKey)
        #expect(try !KavitaProgressCheck.queuedChangeStillGoes(chapterId: 206, seriesId: 4, server: server(page: 60, at: 3600), outbox: setup.outbox))
        #expect(try KavitaProgressCheck.queuedChangeStillGoes(chapterId: 206, seriesId: 4, server: server(page: 60, at: -3600), outbox: setup.outbox),
                "Kavita older: it goes")
    }

    @Test func nothingQueuedHoldsNothing() throws {
        let setup = try setup()
        #expect(try !KavitaProgressCheck.queuedChangeStillGoes(chapterId: 206, seriesId: 4, server: server(page: 60, at: -3600), outbox: setup.outbox))
    }
}
