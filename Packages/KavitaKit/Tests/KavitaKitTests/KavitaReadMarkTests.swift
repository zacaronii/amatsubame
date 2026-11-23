import Core
import CoreTestSupport
import Foundation
import GRDB
import KavitaKit
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
        try await handler(transport).send(try job(.init(mark: .read, seriesId: 4, chapterId: 206, account: account)), media: [])
        try await handler(transport).send(try job(.init(mark: .unread, seriesId: 4, chapterId: 206, account: account)), media: [])
        #expect(paths(transport) == ["/api/Reader/get-progress", "/api/Reader/mark-multiple-read", "/api/Reader/get-progress", "/api/Reader/mark-multiple-unread"])
        let body = try transport.requests[1].jsonBody()
        #expect(body["chapterIds"] as? [Int] == [206] && body["seriesId"] as? Int == 4 && (body["volumeIds"] as? [Int])?.isEmpty == true)
        #expect(body["generateReadingSession"] == nil, "never asks Kavita to record it as reading")
        #expect(!paths(transport).contains("/api/Reader/progress"))
    }

    @Test func aChapterMarkIsDroppedWhenKavitasProgressIsNewer() async throws {
        let transport = StubTransport(routes: ["/api/Reader/get-progress": (200, progressJSON("2026-11-02T00:00:00"))])
        try await handler(transport).send(try job(.init(mark: .unread, seriesId: 4, chapterId: 206, account: account)), media: [])
        #expect(paths(transport) == ["/api/Reader/get-progress"], "read elsewhere after the mark: Kavita's stays")
    }

    @Test func aSeriesMarkReadsTheVolumesOnceAndIsDroppedIfAnyChapterIsNewer() async throws {
        let volumes = try Fixture.data("volumes.json", in: .module)
        let older = StubTransport(routes: ["/api/Series/volumes": (200, volumes), "/api/Reader/mark-read": (200, Data())])
        try await handler(older).send(try job(.init(mark: .read, seriesId: 4, chapterId: nil, account: account)), media: [])
        #expect(paths(older) == ["/api/Series/volumes", "/api/Reader/mark-read"])
        #expect(try older.requests[1].jsonBody()["seriesId"] as? Int == 4)
        #expect(try older.requests[1].jsonBody()["generateReadingSession"] == nil)

        let text = String(decoding: volumes, as: UTF8.self)
        let range = try #require(text.range(of: #""lastReadingProgressUtc": "0001-01-01T00:00:00""#))
        let newer = text.replacingCharacters(in: range, with: #""lastReadingProgressUtc": "2026-11-02T00:00:00""#)
        let dropped = StubTransport(routes: ["/api/Series/volumes": (200, Data(newer.utf8))])
        try await handler(dropped).send(try job(.init(mark: .unread, seriesId: 4, chapterId: nil, account: account)), media: [])
        #expect(paths(dropped) == ["/api/Series/volumes"], "one chapter read elsewhere since: the whole mark goes")
    }

    /// `mark-read` on a series marks its specials too, so they're in the one read: a special
    /// read elsewhere since drops the mark; one read before it doesn't.
    @Test func aSeriesMarkCoversItsSpecials() async throws {
        let text = String(decoding: try Fixture.data("volumes-special.json", in: .module), as: UTF8.self)
        #expect(text.contains(#""isSpecial": true"#))
        let older = StubTransport(routes: ["/api/Series/volumes": (200, Data(text.utf8)), "/api/Reader/mark-read": (200, Data())])
        try await handler(older).send(try job(.init(mark: .read, seriesId: 4, chapterId: nil, account: account)), media: [])
        #expect(paths(older) == ["/api/Series/volumes", "/api/Reader/mark-read"], "the special was read before the mark")

        let newer = text.replacingOccurrences(of: #""lastReadingProgressUtc": "2025-01-17T12:29:51.5000000""#,
                                              with: #""lastReadingProgressUtc": "2026-11-02T00:00:00""#)
        #expect(newer != text)
        let dropped = StubTransport(routes: ["/api/Series/volumes": (200, Data(newer.utf8))])
        try await handler(dropped).send(try job(.init(mark: .read, seriesId: 4, chapterId: nil, account: account)), media: [])
        #expect(paths(dropped) == ["/api/Series/volumes"], "a special read since: dropped")
    }

    @Test func aMarkMadeUnderAnotherAccountWaits() async throws {
        let transport = StubTransport { _ in (200, Data()) }
        await #expect(throws: OutboxWait.self) {
            try await handler(transport, signedIn: "https://kavita.example.ts.net#someone").send(
                try job(.init(mark: .read, seriesId: 4, chapterId: 206, account: account)), media: [])
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
