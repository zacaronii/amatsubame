import Core
import Foundation

// Verified against Kavita 0.9.1.7 (2026-10-30):
// - Auth keys work in the `x-api-key` header on authenticated endpoints; a bad key is 401.
// - `GET /api/Account` returns the user and `kavitaVersion` for any role.
// - `GET /api/Server/server-info-slim` returns `kavitaVersion`, `isDocker`, install info.
// - `GET /api/Plugin/version` only accepts the key as an `apiKey` query parameter (unused).
// - `GET /api/Reader/image` also only accepts `apiKey` as a query parameter (400 with the
//   header), so page-image requests must never be logged or put in a URL cache.

public struct KavitaServerInfo: Decodable, Equatable, Sendable {
    public var kavitaVersion: String
    public var isDocker: Bool?
    public var firstInstallVersion: String?
}

public struct KavitaUser: Decodable, Equatable, Sendable {
    public var id: Int
    public var username: String
    public var roles: [String]
    public var kavitaVersion: String?
}

public struct KavitaConnectionCheck: Equatable, Sendable {
    public var version: String
    public var username: String

    public init(version: String, username: String) {
        self.version = version
        self.username = username
    }
}

public struct KavitaClient: Sendable {
    public let baseURL: URL
    public let authKey: String
    public let http: HTTPClient

    public init(baseURL: URL, authKey: String, http: HTTPClient = HTTPClient()) {
        self.baseURL = baseURL
        self.authKey = authKey
        self.http = http
    }

    func request(_ path: String, query: [URLQueryItem] = []) -> URLRequest {
        var url = baseURL.appending(path: path)
        if !query.isEmpty { url.append(queryItems: query) }
        var request = URLRequest.get(url)
        request.setValue(authKey, forHTTPHeaderField: "x-api-key")
        return request
    }

    func jsonRequest(_ method: String, _ path: String, query: [URLQueryItem] = [], body: some Encodable) throws(ConnectionError) -> URLRequest {
        var url = baseURL.appending(path: path)
        if !query.isEmpty { url.append(queryItems: query) }
        var request: URLRequest
        do {
            request = try .json(method, url, body: body)
        } catch {
            throw .message(error.localizedDescription)
        }
        request.setValue(authKey, forHTTPHeaderField: "x-api-key")
        return request
    }

    private func decode<T: Decodable>(_ type: T.Type, _ request: URLRequest) async throws(ConnectionError) -> T {
        try await http.decode(type, from: request, decoder: KavitaJSON.decoder)
    }

    private func decodeEach<T: Decodable>(_ type: T.Type, _ data: Data) throws(ConnectionError) -> [(T, Data)] {
        do {
            return try KavitaJSON.decodeEach(type, from: data)
        } catch {
            throw .unexpectedResponse(String(describing: error))
        }
    }

    public func serverInfo() async throws(ConnectionError) -> KavitaServerInfo {
        try await http.decode(KavitaServerInfo.self, from: request("api/Server/server-info-slim"))
    }

    public func currentUser() async throws(ConnectionError) -> KavitaUser {
        try await http.decode(KavitaUser.self, from: request("api/Account"))
    }

    // MARK: Library

    public func libraries() async throws(ConnectionError) -> [(KavitaLibrary, raw: Data)] {
        let response = try await http.send(request("api/Library/libraries"))
        return try decodeEach(KavitaLibrary.self, response.data).map { ($0.0, raw: $0.1) }
    }

    /// One page of a library's series, sorted by sort name.
    public func series(libraryId: Int, page: Int, pageSize: Int = 100) async throws(ConnectionError) -> KavitaPage<(KavitaSeries, raw: Data)> {
        let filter = SeriesFilter(libraryId: libraryId)
        let request = try jsonRequest("POST", "api/Series/v2", query: [
            URLQueryItem(name: "pageNumber", value: String(page)),
            URLQueryItem(name: "pageSize", value: String(pageSize)),
        ], body: filter)
        return try await paged(request)
    }

    /// A library's most recently added series, newest first (one page, for the home shelves).
    public func recentlyAdded(libraryId: Int, limit: Int = 12) async throws(ConnectionError) -> [KavitaSeries] {
        var filter = SeriesFilter(libraryId: libraryId)
        filter.sortOptions = .init(sortField: SeriesFilter.SortField.created, isAscending: false)
        let request = try jsonRequest("POST", "api/Series/v2", query: [
            URLQueryItem(name: "pageNumber", value: "1"),
            URLQueryItem(name: "pageSize", value: String(limit)),
        ], body: filter)
        let page: KavitaPage<(KavitaSeries, raw: Data)> = try await paged(request)
        return page.items.map(\.0)
    }

    /// One series by id (search results only carry names and ids).
    public func series(id: Int) async throws(ConnectionError) -> KavitaSeries {
        try await http.decode(KavitaSeries.self, from: request("api/Series/\(id)"), decoder: KavitaJSON.decoder)
    }

    /// The summary, genres and writers Kavita has for a series.
    public func seriesMetadata(seriesId: Int) async throws(ConnectionError) -> KavitaSeriesMetadata {
        try await http.decode(KavitaSeriesMetadata.self, from: request("api/Series/metadata", query: [
            URLQueryItem(name: "seriesId", value: String(seriesId)),
        ]))
    }

    /// Series whose names match `query`, across the libraries the user can see.
    public func search(_ query: String) async throws(ConnectionError) -> [KavitaSearchSeries] {
        try await http.decode(KavitaSearchResult.self, from: request("api/Search/search", query: [
            URLQueryItem(name: "queryString", value: query),
        ])).series
    }

    /// Kavita's "On Deck" (continue reading) across all libraries.
    public func onDeck(pageSize: Int = 20) async throws(ConnectionError) -> [(KavitaSeries, raw: Data)] {
        var request = request("api/Series/on-deck", query: [
            URLQueryItem(name: "pageNumber", value: "1"),
            URLQueryItem(name: "pageSize", value: String(pageSize)),
            URLQueryItem(name: "libraryId", value: "0"),
        ])
        request.httpMethod = "POST"
        return try await paged(request).items
    }

    public func volumes(seriesId: Int) async throws(ConnectionError) -> [(KavitaVolume, raw: Data)] {
        let response = try await http.send(request("api/Series/volumes", query: [URLQueryItem(name: "seriesId", value: String(seriesId))]))
        return try decodeEach(KavitaVolume.self, response.data).map { ($0.0, raw: $0.1) }
    }

    private func paged<T: Decodable & Sendable>(_ request: URLRequest) async throws(ConnectionError) -> KavitaPage<(T, raw: Data)> {
        let response = try await http.send(request)
        let items = try decodeEach(T.self, response.data).map { ($0.0, raw: $0.1) }
        let pagination = (response.response.value(forHTTPHeaderField: "Pagination")?.data(using: .utf8))
            .flatMap { try? JSONDecoder().decode(KavitaPagination.self, from: $0) }
        return KavitaPage(items: items, pagination: pagination)
    }

    // MARK: Reader

    public func chapterInfo(chapterId: Int) async throws(ConnectionError) -> KavitaChapterInfo {
        try await decode(KavitaChapterInfo.self, request("api/Reader/chapter-info", query: [URLQueryItem(name: "chapterId", value: String(chapterId))]))
    }

    /// Page images and sizes give up after this: on a connection that's up but can't reach
    /// Kavita, the default 60 s left reading and downloads hanging.
    public static let readingTimeout: TimeInterval = 20

    public func fileDimensions(chapterId: Int) async throws(ConnectionError) -> [KavitaPageDimension] {
        var request = request("api/Reader/file-dimensions", query: [URLQueryItem(name: "chapterId", value: String(chapterId))])
        request.timeoutInterval = Self.readingTimeout
        return try await decode([KavitaPageDimension].self, request)
    }

    public func progress(chapterId: Int) async throws(ConnectionError) -> KavitaServerProgress {
        try await decode(KavitaServerProgress.self, request("api/Reader/get-progress", query: [URLQueryItem(name: "chapterId", value: String(chapterId))]))
    }

    /// Writes progress. Call only from the outbox handler; UI code enqueues instead.
    public func saveProgress(_ progress: KavitaProgressPayload) async throws(ConnectionError) {
        _ = try await http.send(jsonRequest("POST", "api/Reader/progress", body: progress))
    }

    /// The page image request. The key travels as a query parameter because this
    /// endpoint rejects the header, so the request must not be logged or URL-cached.
    public func pageImageRequest(chapterId: Int, page: Int) -> URLRequest {
        var url = baseURL.appending(path: "api/Reader/image")
        url.append(queryItems: [
            URLQueryItem(name: "chapterId", value: String(chapterId)),
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "extractPdf", value: "false"),
            URLQueryItem(name: "apiKey", value: authKey),
        ])
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Self.readingTimeout)
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        return request
    }

    public func pageImage(chapterId: Int, page: Int) async throws(ConnectionError) -> Data {
        try await http.send(pageImageRequest(chapterId: chapterId, page: page)).data
    }

    /// The chapter's original file (an .epub for books). Verified on Kavita 0.9.1.7:
    /// `application/epub+zip`, accepted with the auth key header.
    public func downloadChapter(chapterId: Int) async throws(ConnectionError) -> Data {
        var request = request("api/Download/chapter", query: [URLQueryItem(name: "chapterId", value: String(chapterId))])
        request.timeoutInterval = 300
        return try await http.send(request).data
    }

    /// One section of a book (an EPUB spine item) as HTML, without its images: what Yomu counts
    /// characters from. Verified on Kavita 0.9.1.7: `page` is 0-based, the same sections as the
    /// file's spine, and fetching doesn't touch reading progress.
    public func bookPage(chapterId: Int, page: Int) async throws(ConnectionError) -> String {
        let request = request("api/Book/\(chapterId)/book-page", query: [URLQueryItem(name: "page", value: String(page))])
        let data = try await http.send(request).data
        guard let html = String(data: data, encoding: .utf8) else { throw .unexpectedResponse("Not UTF-8 text") }
        return html
    }

    public func seriesCoverRequest(seriesId: Int) -> URLRequest {
        var request = request("api/Image/series-cover", query: [URLQueryItem(name: "seriesId", value: String(seriesId))])
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        return request
    }

    public func chapterCoverRequest(chapterId: Int) -> URLRequest {
        var request = request("api/Image/chapter-cover", query: [URLQueryItem(name: "chapterId", value: String(chapterId))])
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        return request
    }

    // MARK: Connection

    /// Checks the URL and key with one authenticated call and reports the server version.
    public func testConnection() async throws(ConnectionError) -> KavitaConnectionCheck {
        let user: KavitaUser
        do {
            user = try await currentUser()
        } catch .unexpectedResponse {
            throw .notThisService("Expected a Kavita server.")
        }
        if let version = user.kavitaVersion {
            return KavitaConnectionCheck(version: version, username: user.username)
        }
        return KavitaConnectionCheck(version: try await serverInfo().kavitaVersion, username: user.username)
    }
}

/// Series filter v2: libraries (field 19) equal to one id, sorted by sort name (field 1).
struct SeriesFilter: Encodable {
    struct Statement: Encodable {
        var field = 19
        var comparison = 0
        var value: String
    }
    struct SortOptions: Encodable {
        var sortField = SortField.sortName
        var isAscending = true
    }
    /// Kavita's SortField values.
    enum SortField {
        static let sortName = 1
        static let created = 2
    }
    var statements: [Statement]
    var combination = 1
    var limitTo = 0
    var sortOptions = SortOptions()

    init(libraryId: Int) {
        statements = [Statement(value: String(libraryId))]
    }
}
