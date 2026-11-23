import Core
import CoreTestSupport
import Foundation
import GRDB
import KavitaKit
import Synchronization
import Testing

/// Mark as Read / Unread: queued with page turns, sent through Kavita's mark endpoints (never
/// `Reader/progress`), dropped when Kavita's progress is newer, and never counted as reading.
@Suite struct KavitaReadMarkTests {
    let base = URL(string: "https://kavita.example.ts.net")!
    let account = "https://kavita.example.ts.net#reader"
    let made = Date(timeIntervalSince1970: 1_793_400_000)   // 2026-10-31

    func job(_ payload: KavitaReadMarkPayload) throws -> OutboxJob {
        OutboxJob(id: 1, kind: .kavitaProgress, coalesceKey: payload.coalesceKey, payload: try JSONEncoder().encode(payload),
                  state: .inFlight, nextAttemptAt: made, createdAt: made, updatedAt: made)
    }

    func handler(_ transport: StubTransport, signedIn: String? = nil) -> KavitaProgressHandler {
        KavitaProgressHandler(account: { signedIn ?? "https://kavita.example.ts.net#reader" }) {
            KavitaClient(baseURL: base, authKey: "k", http: HTTPClient(transport: transport))
        }
    }

    func progressJSON(_ date: String) -> Data {
        Data(#"{"volumeId":206,"chapterId":206,"pageNum":9,"seriesId":4,"libraryId":1,"bookScrollId":null,"lastModifiedUtc":"\#(date)"}"#.utf8)
    }

    func paths(_ transport: StubTransport) -> [String] { transport.requests.map { $0.url!.path() } }

    @Test func aChapterMarkUsesTheMarkEndpointWithoutAReadingSession() async throws {
        let transport = StubTransport(routes: [
            "/api/Reader/get-progress": (200, progressJSON("2026-10-30T00:00:00")),
            "/api/Reader/mark-multiple-read": (200, Data()),
            "/api/Reader/mark-multiple-unread": (200, Data()),
        ])
        try await handler(transport).send(try job(.init(mark: .read, seriesId: 4, chapterId: 206, account: account, madeAt: made)), media: [])
        try await handler(transport).send(try job(.init(mark: .unread, seriesId: 4, chapterId: 206, account: account, madeAt: made)), media: [])
        #expect(paths(transport) == ["/api/Reader/get-progress", "/api/Reader/mark-multiple-read", "/api/Reader/get-progress", "/api/Reader/mark-multiple-unread"])
        let body = try transport.requests[1].jsonBody()
        #expect(body["chapterIds"] as? [Int] == [206] && body["seriesId"] as? Int == 4 && (body["volumeIds"] as? [Int])?.isEmpty == true)
        #expect(body["generateReadingSession"] == nil, "never asks Kavita to record it as reading")
        #expect(!paths(transport).contains("/api/Reader/progress"))
    }

    @Test func aChapterMarkIsDroppedWhenKavitasProgressIsNewer() async throws {
        let transport = StubTransport(routes: ["/api/Reader/get-progress": (200, progressJSON("2026-11-02T00:00:00"))])
        try await handler(transport).send(try job(.init(mark: .unread, seriesId: 4, chapterId: 206, account: account, madeAt: made)), media: [])
        #expect(paths(transport) == ["/api/Reader/get-progress"], "read elsewhere after the mark: Kavita's stays")
    }

    @Test func aSeriesMarkReadsTheVolumesOnceAndIsDroppedIfAnyChapterIsNewer() async throws {
        let volumes = try Fixture.data("volumes.json", in: .module)
        let older = StubTransport(routes: ["/api/Series/volumes": (200, volumes), "/api/Reader/mark-read": (200, Data())])
        try await handler(older).send(try job(.init(mark: .read, seriesId: 4, chapterId: nil, account: account, madeAt: made)), media: [])
        #expect(paths(older) == ["/api/Series/volumes", "/api/Reader/mark-read"])
        #expect(try older.requests[1].jsonBody()["seriesId"] as? Int == 4)
        #expect(try older.requests[1].jsonBody()["generateReadingSession"] == nil)

        let text = String(decoding: volumes, as: UTF8.self)
        let range = try #require(text.range(of: #""lastReadingProgressUtc": "0001-01-01T00:00:00""#))
        let newer = text.replacingCharacters(in: range, with: #""lastReadingProgressUtc": "2026-11-02T00:00:00""#)
        let dropped = StubTransport(routes: ["/api/Series/volumes": (200, Data(newer.utf8))])
        try await handler(dropped).send(try job(.init(mark: .unread, seriesId: 4, chapterId: nil, account: account, madeAt: made)), media: [])
        #expect(paths(dropped) == ["/api/Series/volumes"], "one chapter read elsewhere since: the whole mark goes")
    }

    /// `mark-read` on a series marks its specials too, so they're in the one read: a special
    /// read elsewhere since drops the mark; one read before it doesn't.
    @Test func aSeriesMarkCoversItsSpecials() async throws {
        let text = String(decoding: try Fixture.data("volumes-special.json", in: .module), as: UTF8.self)
        #expect(text.contains(#""isSpecial": true"#))
        let older = StubTransport(routes: ["/api/Series/volumes": (200, Data(text.utf8)), "/api/Reader/mark-read": (200, Data())])
        try await handler(older).send(try job(.init(mark: .read, seriesId: 4, chapterId: nil, account: account, madeAt: made)), media: [])
        #expect(paths(older) == ["/api/Series/volumes", "/api/Reader/mark-read"], "the special was read before the mark")

        let newer = text.replacingOccurrences(of: #""lastReadingProgressUtc": "2025-01-17T12:29:51.5000000""#,
                                              with: #""lastReadingProgressUtc": "2026-11-02T00:00:00""#)
        #expect(newer != text)
        let dropped = StubTransport(routes: ["/api/Series/volumes": (200, Data(newer.utf8))])
        try await handler(dropped).send(try job(.init(mark: .read, seriesId: 4, chapterId: nil, account: account, madeAt: made)), media: [])
        #expect(paths(dropped) == ["/api/Series/volumes"], "a special read since: dropped")
    }

    @Test func aMarkMadeUnderAnotherAccountWaits() async throws {
        let transport = StubTransport { _ in (200, Data()) }
        await #expect(throws: OutboxWait.self) {
            try await handler(transport, signedIn: "https://kavita.example.ts.net#someone").send(
                try job(.init(mark: .read, seriesId: 4, chapterId: 206, account: account, madeAt: made)), media: [])
        }
        #expect(transport.requests.isEmpty)
    }

    @Test func plainProgressStillGoesAsBefore() async throws {
        let transport = StubTransport(routes: [
            "/api/Reader/get-progress": (200, progressJSON("2026-10-30T00:00:00")), "/api/Reader/progress": (200, Data()),
        ])
        let payload = KavitaProgressPayload(volumeId: 206, chapterId: 206, pageNum: 5, seriesId: 4, libraryId: 1)
        let job = OutboxJob(id: 1, kind: .kavitaProgress, coalesceKey: "kavita.chapter.206", payload: try JSONEncoder().encode(payload),
                            state: .inFlight, nextAttemptAt: made, createdAt: made, updatedAt: made)
        try await handler(transport).send(job, media: [])
        #expect(paths(transport) == ["/api/Reader/get-progress", "/api/Reader/progress"])
    }

    // MARK: Judged by when the mark was made (through the real queue)

    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var time: Date
        init(_ time: Date) { self.time = time }
        var now: Date { lock.withLock { time } }
        func set(_ date: Date) { lock.withLock { time = date } }
    }

    /// Queued at T0 (offline), claimed two days later, Kavita changed a day after T0: dropped.
    func sentLate(series: Bool, retriedInBetween: Bool = false) async throws -> [String] {
        let t0 = made
        let clock = Clock(t0)
        let database = try AppDatabase.inMemory()
        let outbox = OutboxStore(database: database) { clock.now }
        let marking = KavitaReadMarking(database: database, outbox: outbox)
        let chapter = KavitaReadMarking.Chapter(chapterId: 206, volumeId: 206, pages: 10)
        if series {
            try marking.markSeries(false, [chapter], seriesId: 4, libraryId: 1, account: account)
        } else {
            try marking.mark(false, [chapter], seriesId: 4, libraryId: 1, account: account)
        }
        if retriedInBetween {
            clock.set(t0.addingTimeInterval(3600))
            let first = try #require(try outbox.claimDueJobs(kinds: [.kavitaProgress]).first)
            try outbox.markRetry(first.job.id!, error: "offline")
        }
        clock.set(t0.addingTimeInterval(2 * 86_400))
        let claimed = try #require(try outbox.claimDueJobs(kinds: [.kavitaProgress]).first)
        let volumes = String(decoding: try Fixture.data("volumes.json", in: .module), as: UTF8.self)
            .replacingOccurrences(of: #""lastReadingProgressUtc": "0001-01-01T00:00:00""#, with: #""lastReadingProgressUtc": "2026-11-01T00:00:00""#)
        let transport = StubTransport(routes: [
            "/api/Reader/get-progress": (200, progressJSON("2026-11-01T00:00:00")),   // a day after T0
            "/api/Series/volumes": (200, Data(volumes.utf8)),
            "/api/Reader/mark-multiple-unread": (200, Data()), "/api/Reader/mark-unread": (200, Data()),
        ])
        try await handler(transport).send(claimed.job, media: [])
        return paths(transport)
    }

    @Test func aChapterMarkSentLateIsJudgedByWhenItWasMade() async throws {
        #expect(try await sentLate(series: false) == ["/api/Reader/get-progress"], "read elsewhere after the mark: dropped")
    }

    @Test func aSeriesMarkSentLateIsJudgedByWhenItWasMade() async throws {
        #expect(try await sentLate(series: true) == ["/api/Series/volumes"])
    }

    @Test func aRetriedMarkIsStillJudgedByWhenItWasMade() async throws {
        #expect(try await sentLate(series: false, retriedInBetween: true) == ["/api/Reader/get-progress"])
    }

    /// A book marked unread: Kavita sets page 0 but keeps its old place, with a newer date. After
    /// the mark went, this device's row is moved past Kavita's date (read back once), so here it
    /// starts over at the top; a row changed since the mark (a page turned) is left alone.
    @Test func afterAnUnreadMarkThisDevicesStartStaysNewer() async throws {
        let clock = Clock(made)
        let database = try AppDatabase.inMemory()
        let outbox = OutboxStore(database: database) { clock.now }
        let progress = ReadingProgressStore(database: database)
        let marking = KavitaReadMarking(database: database, outbox: outbox)
        try marking.mark(false, [.init(chapterId: 206, volumeId: 206, pages: 10), .init(chapterId: 207, volumeId: 207, pages: 10)],
                         seriesId: 4, libraryId: 1, account: account)
        // Chapter 207 is opened and a page turned before its mark is sent.
        try progress.save(LocalReadingProgress(chapterId: 207, seriesId: 4, volumeId: 207, libraryId: 1, page: 2, pages: 10,
                                               updatedAt: made.addingTimeInterval(30)))
        clock.set(made.addingTimeInterval(60))
        let reads = Mutex(0)
        let kept = #"{"volumeId":206,"chapterId":206,"pageNum":0,"seriesId":4,"libraryId":1,"bookScrollId":"//body/div[1]/p[9]","lastModifiedUtc":"2026-10-31T00:02:00"}"#
        let transport = StubTransport { request in
            switch request.url!.path() {
            case "/api/Reader/get-progress":
                let first = reads.withLock { n in defer { n += 1 }; return n % 2 == 0 }
                return (200, first ? progressJSON("2026-10-30T00:00:00") : Data(kept.utf8))
            default: return (200, Data())
            }
        }
        let handler = KavitaProgressHandler(account: { self.account }, progress: progress) {
            KavitaClient(baseURL: base, authKey: "k", http: HTTPClient(transport: transport))
        }
        for claimed in try outbox.claimDueJobs(kinds: [.kavitaProgress]) { try await handler.send(claimed.job, media: []) }
        #expect(paths(transport).filter { $0 == "/api/Reader/mark-multiple-unread" }.count == 2)
        let kavitaDate = try #require(ISO8601DateFormatter().date(from: "2026-10-31T00:02:00Z"))
        let row = try #require(try progress.progress(chapterId: 206))
        #expect(row.page == 0 && row.updatedAt == kavitaDate.addingTimeInterval(1), "moved past Kavita's date")
        #expect(row.updatedAt > kavitaDate, "newer than Kavita's row with the old place (opening: BookTests)")
        #expect(try progress.progress(chapterId: 207)?.page == 2, "a page turned since is left alone")
    }

    /// The series path: one read of the volumes after the mark; each row the mark wrote moved
    /// past its own chapter's date, a chapter Kavita gives no date for left alone.
    @Test func afterASeriesUnreadEachRowPassesItsOwnChapter() async throws {
        let clock = Clock(made)
        let database = try AppDatabase.inMemory()
        let outbox = OutboxStore(database: database) { clock.now }
        let progress = ReadingProgressStore(database: database)
        let volumes = String(decoding: try Fixture.data("volumes.json", in: .module), as: UTF8.self)
        let ids = try #require(try JSONSerialization.jsonObject(with: Data(volumes.utf8)) as? [[String: Any]])
            .flatMap { ($0["chapters"] as? [[String: Any]]) ?? [] }.compactMap { $0["id"] as? Int }
        #expect(ids.count >= 3)
        try KavitaReadMarking(database: database, outbox: outbox)
            .markSeries(false, ids.map { .init(chapterId: $0, volumeId: 1, pages: 10) }, seriesId: 4, libraryId: 1, account: account)
        clock.set(made.addingTimeInterval(60))
        // After the mark: two chapters with Kavita's new dates, the rest never read (year 1).
        var after = volumes
        for (n, date) in ["2026-10-31T00:05:00", "2026-10-31T00:07:00"].enumerated() {
            let range = try #require(after.range(of: #""lastReadingProgressUtc": "0001-01-01T00:00:00""#), "chapter \(n)")
            after.replaceSubrange(range, with: #""lastReadingProgressUtc": "\#(date)""#)
        }
        let reads = Mutex(0)
        let answers = [Data(volumes.utf8), Data(after.utf8)]
        let transport = StubTransport { request in
            switch request.url!.path() {
            case "/api/Series/volumes":
                let n = reads.withLock { n in defer { n += 1 }; return n }
                return (200, answers[min(n, 1)])
            default: return (200, Data())
            }
        }
        let handler = KavitaProgressHandler(account: { self.account }, progress: progress) {
            KavitaClient(baseURL: base, authKey: "k", http: HTTPClient(transport: transport))
        }
        try await handler.send(try #require(try outbox.claimDueJobs(kinds: [.kavitaProgress]).first).job, media: [])
        #expect(paths(transport) == ["/api/Series/volumes", "/api/Reader/mark-unread", "/api/Series/volumes"])
        let rows = try ids.map { try #require(try progress.progress(chapterId: $0)) }
        let formatter = ISO8601DateFormatter()
        let settled = rows.filter { $0.updatedAt > made.addingTimeInterval(1) }.map(\.updatedAt).sorted()
        #expect(settled == ["2026-10-31T00:05:01Z", "2026-10-31T00:07:01Z"].compactMap(formatter.date(from:)), "each past its own chapter")
        #expect(rows.filter { abs($0.updatedAt.timeIntervalSince(made)) < 0.01 }.count == ids.count - 2, "no date: left as the mark wrote it")
    }

    /// The read-back after a sent unread is best effort: if it fails the mark still counts as
    /// sent (no retry, which would only find its own newer date); the row isn't settled, so this
    /// device follows Kavita's kept place for that book.
    @Test func aFailedReadBackDoesntFailTheMark() async throws {
        let clock = Clock(made)
        let database = try AppDatabase.inMemory()
        let outbox = OutboxStore(database: database) { clock.now }
        let progress = ReadingProgressStore(database: database)
        try KavitaReadMarking(database: database, outbox: outbox)
            .mark(false, [.init(chapterId: 206, volumeId: 206, pages: 10)], seriesId: 4, libraryId: 1, account: account)
        let reads = Mutex(0)
        let transport = StubTransport { request in
            switch request.url!.path() {
            case "/api/Reader/get-progress":
                let n = reads.withLock { n in defer { n += 1 }; return n }
                return n == 0 ? (200, progressJSON("2026-10-30T00:00:00")) : (503, Data())
            default: return (200, Data())
            }
        }
        let handler = KavitaProgressHandler(account: { self.account }, progress: progress) {
            KavitaClient(baseURL: base, authKey: "k", http: HTTPClient(transport: transport))
        }
        try await handler.send(try #require(try outbox.claimDueJobs(kinds: [.kavitaProgress]).first).job, media: [])
        #expect(paths(transport) == ["/api/Reader/get-progress", "/api/Reader/mark-multiple-unread", "/api/Reader/get-progress"])
        #expect(abs(try #require(try progress.progress(chapterId: 206)).updatedAt.timeIntervalSince(made)) < 0.01, "not settled")
    }

    /// Without the outbox to tell this device's own sends apart (as here), a newer date on Kavita
    /// drops the mark; with it, see `KavitaPageTurnTests.aMarkMadeWhileThisDevicesTurnWasOnItsWayIsSent`.
    @Test func aMarkMadeBeforeThisDevicesPreviousChangeArrivedIsDropped() async throws {
        let transport = StubTransport(routes: ["/api/Reader/get-progress": (200, progressJSON("2026-10-31T00:00:05"))])
        try await handler(transport).send(try job(.init(mark: .unread, seriesId: 4, chapterId: 206, account: account, madeAt: made)), media: [])
        #expect(paths(transport) == ["/api/Reader/get-progress"])
    }

    // MARK: On the device

    @Test func markingWritesProgressAndJobsTogetherAndIsNotReading() throws {
        let database = try AppDatabase.inMemory()
        let outbox = OutboxStore(database: database)
        let marking = KavitaReadMarking(database: database, outbox: outbox)
        // A page turn of chapter 1 waiting: the mark replaces it (the latest is sent).
        try outbox.enqueue(KavitaProgressPayload(volumeId: 10, chapterId: 1, pageNum: 3, seriesId: 4, libraryId: 1),
                           kind: .kavitaProgress, coalesceKey: "kavita.chapter.1")
        let chapters = [KavitaReadMarking.Chapter(chapterId: 1, volumeId: 10, pages: 20), .init(chapterId: 2, volumeId: 10, pages: 30)]
        try marking.mark(true, chapters, seriesId: 4, libraryId: 1, account: account)
        let jobs = try outbox.jobs(states: [.pending])
        #expect(jobs.count == 2)
        #expect(try jobs.allSatisfy { try $0.decodePayload(KavitaReadMarkPayload.self).mark == .read })
        let progress = ReadingProgressStore(database: database)
        #expect(try progress.progress(chapterId: 2)?.page == 29)
        #expect(try database.reader.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM activitySession") } == 0, "no reading time, characters or streak day")

        // The series: one job, the chapters' queued ones replaced.
        try marking.markSeries(false, chapters, seriesId: 4, libraryId: 1, account: account)
        let after = try outbox.jobs(states: [.pending])
        #expect(after.map(\.coalesceKey) == ["kavita.series.4"])
        #expect(try progress.progress(chapterId: 1)?.page == 0)
        #expect(try database.reader.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM activitySession") } == 0)
        // A page turn after it goes after it.
        try outbox.enqueue(KavitaProgressPayload(volumeId: 10, chapterId: 1, pageNum: 4, seriesId: 4, libraryId: 1),
                           kind: .kavitaProgress, coalesceKey: "kavita.chapter.1")
        let order = try outbox.claimDueJobs(kinds: [.kavitaProgress]).map(\.job.coalesceKey)
        #expect(order == ["kavita.series.4", "kavita.chapter.1"], "sent in the order made")
    }
}
