import Core
import CoreTestSupport
import Foundation
@testable import KavitaKit
import Testing

@Suite struct KavitaReaderEndpointTests {
    let base = URL(string: "https://kavita.example.ts.net")!

    func fixture(_ name: String) throws -> Data { try Fixture.data(name, in: .module) }

    func client(_ transport: StubTransport) -> KavitaClient {
        KavitaClient(baseURL: base, authKey: "secret", http: HTTPClient(transport: transport))
    }

    @Test func librariesFlagMangaReadableTypes() async throws {
        let libraries = try await client(StubTransport(routes: ["/api/Library/libraries": (200, try fixture("libraries.json"))])).libraries()
        #expect(libraries.map(\.0.id) == [2, 1, 3, 4])
        #expect(libraries.filter(\.0.isMangaReadable).map(\.0.id) == [1, 3])
        #expect(!libraries[0].raw.isEmpty)
    }

    /// A book section as Kavita's reader gets it: HTML in a `<div>` with its styles inline
    /// (shape recorded from Kavita 0.9.1.7; the text here is made up).
    @Test func bookPageAsksForOneSection() async throws {
        let transport = StubTransport(routes: ["/api/Book/7/book-page": (200, try fixture("book-page.html"))])
        let html = try await client(transport).bookPage(chapterId: 7, page: 3)
        #expect(html.hasPrefix("<div class=\"vrtl"))
        #expect(html.contains("<ruby>試験<rt>しけん</rt></ruby>"))
        let request = try #require(transport.requests.first)
        #expect(request.url?.query == "page=3")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "secret")
    }

    @Test func seriesSendsLibraryFilterAndReadsPagination() async throws {
        let transport = StubTransport { request in
            let fixture = try Fixture.data("series-v2.json", in: .module)
            return (200, fixture)
        }
        let paginated = PaginatedTransport(inner: transport, pagination: #"{"currentPage":1,"itemsPerPage":3,"totalItems":30,"totalPages":10}"#)
        let client = KavitaClient(baseURL: base, authKey: "secret", http: HTTPClient(transport: paginated))

        let page = try await client.series(libraryId: 1, page: 1, pageSize: 3)
        #expect(page.items.count == 3)
        #expect(page.items.allSatisfy { $0.0.libraryId == 1 && !$0.0.isEpub })
        #expect(page.pagination?.totalItems == 30)
        #expect(page.hasMore)

        let request = try #require(transport.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.query == "pageNumber=1&pageSize=3")
        let body = try request.jsonBody()
        let statement = try #require((body["statements"] as? [[String: Any]])?.first)
        #expect(statement["field"] as? Int == 19)
        #expect(statement["comparison"] as? Int == 0)
        #expect(statement["value"] as? String == "1")
        #expect((body["sortOptions"] as? [String: Any])?["sortField"] as? Int == 1)
    }

    @Test func onDeckDecodesMixedFormats() async throws {
        let transport = StubTransport(routes: ["/api/Series/on-deck": (200, try fixture("on-deck.json"))])
        let series = try await client(transport).onDeck().map(\.0)
        #expect(series.count == 5)
        #expect(series.filter(\.isEpub).map(\.id) == [67, 83])
        #expect(series.first?.latestReadDate != nil)
        #expect(transport.requests[0].httpMethod == "POST")
    }

    @Test func volumesGroupIntoContents() async throws {
        let volumes = try await client(StubTransport(routes: ["/api/Series/volumes": (200, try fixture("volumes.json"))])).volumes(seriesId: 4)
        let contents = KavitaSeriesContents(volumes: volumes.map(\.0))
        #expect(contents.volumes.map(\.number) == [1, 2, 3])
        #expect(contents.volumes[0].chapters[0].isWholeVolume)
        #expect(contents.specials.isEmpty)
        #expect(contents.continueChapter?.id == contents.volumes[0].chapters[0].id)
        #expect(contents.chapter(after: contents.volumes[0].chapters[0].id)?.id == contents.volumes[1].chapters[0].id)
    }

    @Test func specialsVolumeIsSeparated() async throws {
        let volumes = try await client(StubTransport(routes: ["/api/Series/volumes": (200, try fixture("volumes-special.json"))])).volumes(seriesId: 9)
        let contents = KavitaSeriesContents(volumes: volumes.map(\.0))
        #expect(contents.volumes.isEmpty)
        #expect(contents.specials.map(\.id) == [207])
        #expect(contents.continueChapter?.id == 207)
    }

    @Test func chapterInfoAndDimensions() async throws {
        let transport = StubTransport(routes: [
            "/api/Reader/chapter-info": (200, try fixture("chapter-info.json")),
            "/api/Reader/file-dimensions": (200, try fixture("file-dimensions.json")),
        ])
        let info = try await client(transport).chapterInfo(chapterId: 207)
        #expect(info.pages == 188)
        #expect(info.seriesId == 9)
        let dims = try await client(transport).fileDimensions(chapterId: 207)
        #expect(dims.count == 8)
        #expect(dims[1].pageNumber == 1)
        #expect(abs(dims[0].aspectRatio - 1650.0 / 2250.0) < 0.0001)
    }

    @Test func serverProgressParsesKavitaDates() async throws {
        let read = try await client(StubTransport(routes: ["/api/Reader/get-progress": (200, try fixture("get-progress.json"))])).progress(chapterId: 207)
        #expect(read.pageNum == 21)
        let expected = KavitaJSON.parseDate("2025-01-17T12:29:51.5000000")
        #expect(read.lastModifiedUtc == expected)
        #expect(expected.map { abs($0.timeIntervalSince1970 - 1_737_116_991.5) < 0.001 } == true)

        let unread = try await client(StubTransport(routes: ["/api/Reader/get-progress": (200, try fixture("get-progress-none.json"))])).progress(chapterId: 206)
        #expect(unread.pageNum == 0)
        #expect(unread.lastModifiedUtc == nil)
    }

    @Test func saveProgressPostsExplicitNullScrollId() async throws {
        let transport = StubTransport(routes: ["/api/Reader/progress": (200, Data())])
        try await client(transport).saveProgress(KavitaProgressPayload(volumeId: 206, chapterId: 206, pageNum: 5, seriesId: 4, libraryId: 1))
        let request = try #require(transport.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "secret")
        let body = try request.jsonBody()
        #expect(body["pageNum"] as? Int == 5)
        #expect(body.keys.contains("bookScrollId"))
        #expect(body["bookScrollId"] is NSNull)
    }

    @Test func pageImageCarriesKeyInQueryOnly() throws {
        let request = KavitaClient(baseURL: base, authKey: "secret").pageImageRequest(chapterId: 207, page: 3)
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.first { $0.name == "apiKey" }?.value == "secret")
        #expect(items.first { $0.name == "page" }?.value == "3")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == nil)
        #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
    }

    @Test(arguments: [
        ("2025-01-02T03:04:05.6789012", 1_735_787_045.6789012),
        ("2025-01-02T03:04:05Z", 1_735_787_045.0),
        ("2025-01-02T03:04:05", 1_735_787_045.0),
    ])
    func parsesDateVariants(text: String, expected: Double) {
        let date = KavitaJSON.parseDate(text)
        #expect(date.map { abs($0.timeIntervalSince1970 - expected) < 0.001 } == true)
    }

    @Test func yearOneIsUnset() {
        #expect(KavitaJSON.parseDate("0001-01-01T00:00:00") == nil)
    }
}

@Suite struct KavitaSeriesContentsTests {
    func chapter(_ id: Int, volume: Int, sort: Double, read: Bool = false) -> KavitaChapter {
        KavitaChapter(id: id, volumeId: volume, number: String(sort), sortOrder: sort, pages: 10, pagesRead: read ? 10 : 0)
    }

    @Test func orderIsVolumesThenLooseChaptersWithSpecialsApart() {
        let contents = KavitaSeriesContents(volumes: [
            KavitaVolume(id: 3, seriesId: 1, name: "100000", number: KavitaVolume.specialNumber, pages: 10, pagesRead: 0,
                         chapters: [chapter(30, volume: 3, sort: 1)]),
            KavitaVolume(id: 2, seriesId: 1, name: "-100000", number: KavitaVolume.looseLeafNumber, pages: 20, pagesRead: 0,
                         chapters: [chapter(22, volume: 2, sort: 12), chapter(21, volume: 2, sort: 11)]),
            KavitaVolume(id: 1, seriesId: 1, name: "1", number: 1, pages: 20, pagesRead: 20,
                         chapters: [chapter(12, volume: 1, sort: 2, read: true), chapter(11, volume: 1, sort: 1, read: true)]),
        ])
        #expect(contents.readingOrder.map(\.id) == [11, 12, 21, 22])
        #expect(contents.specials.map(\.id) == [30])
        #expect(contents.continueChapter?.id == 21)
        #expect(contents.chapter(after: 12)?.id == 21)
        #expect(contents.chapter(after: 22) == nil)
        #expect(contents.chapter(after: 30) == nil)
    }

    @Test func fullyReadSeriesContinuesFromStart() {
        let contents = KavitaSeriesContents(volumes: [
            KavitaVolume(id: 1, seriesId: 1, name: "1", number: 1, pages: 10, pagesRead: 10, chapters: [chapter(11, volume: 1, sort: 1, read: true)]),
        ])
        #expect(contents.continueChapter?.id == 11)
    }
}

/// Adds a `Pagination` header to every response from `inner`.
struct PaginatedTransport: HTTPTransport {
    let inner: StubTransport
    let pagination: String

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let (data, response) = try await inner.data(for: request)
        let http = response as! HTTPURLResponse
        let headers = ["Content-Type": "application/json", "Pagination": pagination]
        return (data, HTTPURLResponse(url: http.url!, statusCode: http.statusCode, httpVersion: nil, headerFields: headers)!)
    }
}

@Suite struct KavitaNamingTests {
    @Test func displayNameIsKavitasPrimaryName() {
        let series = KavitaSeries(id: 1, name: "Tooi Mori no Mahoutsukai", localizedName: "먼 숲의 마법사", libraryId: 1, format: 1, pages: 1, pagesRead: 0)
        #expect(series.displayName == "Tooi Mori no Mahoutsukai")
    }
}
