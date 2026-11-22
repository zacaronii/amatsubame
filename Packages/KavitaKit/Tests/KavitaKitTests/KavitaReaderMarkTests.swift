import Core
import CoreTestSupport
import Foundation
@testable import KavitaKit
import Testing

/// Bookmarks and highlights on Kavita: the client's shapes (recorded fixtures with made-up text),
/// the outbox handler and the refresh.
@Suite struct KavitaReaderMarkTests {
    let base = URL(string: "https://kavita.example.ts.net")!
    let account = "https://kavita.example.ts.net#reader"

    func fixture(_ name: String) throws -> Data { try Fixture.data(name, in: .module) }

    func client(_ transport: StubTransport) -> KavitaClient {
        KavitaClient(baseURL: base, authKey: "k", http: HTTPClient(transport: transport))
    }

    struct Setup {
        let store: ReaderMarkStore
        let outbox: OutboxStore
    }

    func setup() throws -> Setup {
        let database = try AppDatabase.inMemory()
        return Setup(store: ReaderMarkStore(database: database), outbox: OutboxStore(database: database))
    }

    func highlight(note: String? = nil) -> ReaderMark {
        ReaderMark(account: account, kind: .highlight, libraryId: 40, seriesId: 30, volumeId: 20, chapterId: 10, page: 2,
                   xpath: "//body/div[1]/p[3]", endXPath: "//body/div[1]/p[3]", text: "テスト", note: note, slot: 1,
                   state: .pendingCreate, createdAt: .now, updatedAt: .now)
    }

    func pageBookmark() -> ReaderMark {
        ReaderMark(account: account, kind: .pageBookmark, libraryId: 41, seriesId: 31, volumeId: 21, chapterId: 11, page: 12,
                   state: .pendingCreate, createdAt: .now, updatedAt: .now)
    }

    func send(_ mark: ReaderMark, _ setup: Setup, _ transport: StubTransport) async throws {
        let job = OutboxJob(id: 1, kind: .kavitaReaderMark, payload: try JSONEncoder().encode(ReaderMarkJob(markId: mark.id!)),
                            state: .inFlight, nextAttemptAt: .now, createdAt: .now, updatedAt: .now)
        try await KavitaReaderMarkHandler(store: setup.store) { client(transport) }.send(job, media: [])
    }

    func annotationJSON(id: Int) -> Data {
        Data(#"{"id":\#(id),"xPath":"//body/div[1]/p[3]","endingXPath":"//body/div[1]/p[3]","selectedText":"テスト","highlightCount":3,"containsSpoiler":false,"pageNumber":2,"selectedSlotIndex":1,"likes":[],"chapterId":10,"volumeId":20,"seriesId":30,"libraryId":40,"ownerUserId":7}"#.utf8)
    }

    // MARK: Shapes

    @Test func decodesTheRecordedShapes() throws {
        let annotations = try KavitaJSON.decoder.decode([KavitaAnnotation].self, from: fixture("annotations.json"))
        #expect(annotations.count == 2)
        let mark = annotations[0].mark(account: account)
        #expect(mark.kind == .highlight && mark.serverId == 41 && mark.page == 2 && mark.slot == 1)
        #expect(mark.note == "a note" && mark.endXPath == "//body/div[1]/p[4]")
        #expect(annotations[1].mark(account: account).note == nil, "an empty comment is no note")

        let toc = try KavitaJSON.decoder.decode([KavitaPersonalToC].self, from: fixture("ptoc.json"))
        #expect(toc.first?.mark(account: account, libraryId: 40, seriesId: 30, volumeId: 20).serverKey == "10/4/テスト用のしおり")
        let pages = try KavitaJSON.decoder.decode([KavitaPageBookmark].self, from: fixture("series-bookmarks.json"))
        #expect(pages.first?.mark(account: account, libraryId: 41).serverKey == "11/12")
    }

    @Test func aHighlightSendsNothingAboutWhoMaySeeIt() throws {
        let body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(KavitaAnnotation(highlight(note: "a <b> & c")))) as! [String: Any]
        #expect(body["containsSpoiler"] as? Bool == false)
        #expect(body["commentHtml"] as? String == "<p>a &lt;b&gt; &amp; c</p>")
        #expect(body["highlightCount"] as? Int == 3)
        #expect(body.keys.contains { $0.lowercased().contains("share") } == false)
    }

    // MARK: The handler

    @Test func makingAHighlightKeepsKavitasId() async throws {
        let setup = try setup()
        let mark = try setup.store.add(highlight(), outbox: setup.outbox)
        let transport = StubTransport(routes: ["/api/Annotation/create": (200, annotationJSON(id: 41))])
        try await send(mark, setup, transport)
        let row = try #require(try setup.store.mark(mark.id!))
        #expect(row.state == .synced && row.serverId == 41)
        #expect(try transport.requests[0].jsonBody()["selectedSlotIndex"] as? Int == 1)
    }

    @Test func anEditWhileTheMakeWasOnItsWayIsSentNext() async throws {
        let setup = try setup()
        let mark = try setup.store.add(highlight(), outbox: setup.outbox)
        let store = setup.store, outbox = setup.outbox
        let transport = StubTransport { _ in
            // The note is written while the make is with the server.
            try store.edit(mark.id!, note: "later", slot: 2, outbox: outbox)
            return (200, annotationJSON(id: 41))
        }
        try await send(mark, setup, transport)
        let row = try #require(try setup.store.mark(mark.id!))
        #expect(row.state == .pendingUpdate && row.serverId == 41 && row.note == "later")
    }

    @Test func anEditToAHighlightRemovedElsewhereMakesItAgainOnce() async throws {
        let setup = try setup()
        var mark = try setup.store.add(highlight(), outbox: setup.outbox)
        try setup.store.didSend(mark, serverId: 41)
        try setup.store.edit(mark.id!, note: "n", slot: 1, outbox: setup.outbox)
        mark = try #require(try setup.store.mark(mark.id!))
        let transport = StubTransport(routes: [
            "/api/Annotation/update": (400, Data("Something went wrong".utf8)),
            "/api/Annotation/41": (404, Data()),
            "/api/Annotation/create": (200, annotationJSON(id: 57)),
        ])
        try await send(mark, setup, transport)
        #expect(transport.requests.map { $0.url!.path() } == ["/api/Annotation/update", "/api/Annotation/41", "/api/Annotation/create"])
        let row = try #require(try setup.store.mark(mark.id!))
        #expect(row.state == .synced && row.serverId == 57)
    }

    @Test func aRefusedEditOfAHighlightThatStillExistsNeedsTheUser() async throws {
        let setup = try setup()
        var mark = try setup.store.add(highlight(), outbox: setup.outbox)
        try setup.store.didSend(mark, serverId: 41)
        try setup.store.edit(mark.id!, note: "n", slot: 1, outbox: setup.outbox)
        mark = try #require(try setup.store.mark(mark.id!))
        let transport = StubTransport(routes: ["/api/Annotation/update": (400, Data()), "/api/Annotation/41": (200, annotationJSON(id: 41))])
        await #expect(throws: OutboxPermanentFailure.self) { try await send(mark, setup, transport) }
        #expect(!transport.requests.contains { $0.url!.path().hasSuffix("/create") }, "nothing made")
    }

    @Test func removingSomethingAlreadyGoneIsDone() async throws {
        let setup = try setup()
        let mark = try setup.store.add(highlight(), outbox: setup.outbox)
        try setup.store.didSend(mark, serverId: 41)
        try setup.store.remove(mark.id!, outbox: setup.outbox)
        let transport = StubTransport { request in
            request.httpMethod == "DELETE" ? (400, Data("Couldn't delete annotation".utf8)) : (404, Data())
        }
        try await send(try #require(try setup.store.mark(mark.id!)), setup, transport)
        #expect(try setup.store.mark(mark.id!) == nil)
        #expect(transport.requests.count == 2)
    }

    @Test func aHighlightRemovedBeforeItWasSentNeverReachesKavita() async throws {
        let setup = try setup()
        let mark = try setup.store.add(highlight(), outbox: setup.outbox)
        try setup.store.remove(mark.id!, outbox: setup.outbox)
        let transport = StubTransport { _ in (500, Data()) }
        try await send(try #require(try setup.store.mark(mark.id!)), setup, transport)
        #expect(transport.requests.isEmpty)
        #expect(try setup.store.mark(mark.id!) == nil)
    }

    @Test func aServerWithoutAnnotationsStopsBeingOfferedThem() async throws {
        let setup = try setup()
        let mark = try setup.store.add(highlight(), outbox: setup.outbox)
        let transport = StubTransport(routes: [:])  // every route 404, as before Kavita 0.8.8
        try await send(mark, setup, transport)  // no error: nothing waits to sync for ever
        #expect(try !setup.store.isAvailable(.annotations, account: account))
        #expect(try setup.store.mark(mark.id!) == nil, "the unsent highlight goes")
        #expect(transport.requests.count == 1)

        // A refresh finds the same, without failing.
        let refresh = StubTransport(routes: ["/api/Account": (200, try fixture("account-bookmark-role.json"))])
        let fresh = try self.setup()
        try await KavitaReaderMarkSync(client: client(refresh), store: fresh.store, outbox: fresh.outbox, account: account)
            .refresh(seriesId: 30, libraryId: 40, isBook: true)
        #expect(try !fresh.store.isAvailable(.annotations, account: account))
    }

    @Test func pageBookmarksWithoutTheBookmarkRoleStopBeingOffered() async throws {
        let setup = try setup()
        let mark = try setup.store.add(pageBookmark(), outbox: setup.outbox)
        let transport = StubTransport(routes: ["/api/Reader/bookmark": (403, Data()), "/api/Account": (200, try fixture("account.json").withRoles(["Login"]))])
        try await send(mark, setup, transport)
        #expect(try !setup.store.isAvailable(.pageBookmarks, account: account))
        #expect(try setup.store.mark(mark.id!) == nil)

        // With the role, a refusal is the key's: the user signs in again.
        let other = try self.setup()
        let again = try other.store.add(pageBookmark(), outbox: other.outbox)
        let withRole = StubTransport(routes: ["/api/Reader/bookmark": (401, Data()), "/api/Account": (200, try fixture("account-bookmark-role.json"))])
        await #expect(throws: OutboxPermanentFailure.self) { try await send(again, other, withRole) }
    }

    @Test func otherRefusalsNeedTheUserAndOutagesRetry() async throws {
        let setup = try setup()
        let mark = try setup.store.add(pageBookmark(), outbox: setup.outbox)
        await #expect(throws: OutboxPermanentFailure.self) {
            try await send(mark, setup, StubTransport { _ in (400, Data()) })
        }
        await #expect(throws: ConnectionError.server(status: 503)) {
            try await send(mark, setup, StubTransport { _ in (503, Data()) })
        }
    }

    // MARK: Refresh

    @Test func aRefreshTakesOnlyThisUsersHighlightsAndTheVolumesBookmarks() async throws {
        let setup = try setup()
        let transport = StubTransport(routes: [
            "/api/Account": (200, try fixture("account-bookmark-role.json")),
            "/api/Annotation/all-for-series": (200, try fixture("annotations.json")),
            "/api/Reader/ptoc": (200, try fixture("ptoc.json")),
        ])
        try await KavitaReaderMarkSync(client: client(transport), store: setup.store, outbox: setup.outbox, account: account)
            .refresh(seriesId: 30, libraryId: 40, isBook: true, chapters: [(chapterId: 10, volumeId: 20)])
        let marks = try setup.store.marks(account: account, seriesId: 30)
        #expect(marks.filter { $0.kind == .highlight }.map(\.serverId) == [41], "not someone else's (owner 8)")
        #expect(marks.filter { $0.kind == .bookBookmark }.map(\.page) == [4])
        #expect(marks.allSatisfy { $0.state == .synced })
    }

    @Test func aMangaRefreshNotesTheBookmarkRole() async throws {
        let setup = try setup()
        let transport = StubTransport(routes: [
            "/api/Account": (200, try fixture("account.json").withRoles(["Login"])),
            "/api/Reader/series-bookmarks": (200, try fixture("series-bookmarks.json")),
        ])
        try await KavitaReaderMarkSync(client: client(transport), store: setup.store, outbox: setup.outbox, account: account)
            .refresh(seriesId: 31, libraryId: 41, isBook: false)
        #expect(try !setup.store.isAvailable(.pageBookmarks, account: account))
        #expect(try setup.store.marks(account: account, seriesId: 31).map(\.page) == [12], "bookmarks made in Kavita still show")
    }
}

extension Data {
    func withRoles(_ roles: [String]) throws -> Data {
        var object = try JSONSerialization.jsonObject(with: self) as! [String: Any]
        object["roles"] = roles
        return try JSONSerialization.data(withJSONObject: object)
    }
}
