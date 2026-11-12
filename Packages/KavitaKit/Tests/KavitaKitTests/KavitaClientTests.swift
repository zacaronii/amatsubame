import Core
import CoreTestSupport
import Foundation
import KavitaKit
import Testing

@Suite struct KavitaClientTests {
    let base = URL(string: "https://kavita.example.ts.net/sub")!

    func fixture(_ name: String) throws -> Data { try Fixture.data(name, in: .module) }

    @Test func testConnectionReportsVersionAndUser() async throws {
        let transport = StubTransport(routes: ["/api/Account": (200, try fixture("account.json"))])
        let client = KavitaClient(baseURL: base, authKey: "secret", http: HTTPClient(transport: transport))

        let check = try await client.testConnection()
        #expect(check == KavitaConnectionCheck(version: "0.9.1.7", username: "reader"))

        let request = try #require(transport.requests.first)
        #expect(request.url?.absoluteString == "https://kavita.example.ts.net/sub/api/Account")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "secret")
        #expect(request.url?.query == nil, "the key must not leak into URLs")
    }

    @Test func downloadsChapterFileWithAuthHeader() async throws {
        let epub = Data("PK\u{3}\u{4}epub".utf8)
        let stub = StubTransport(routes: ["api/Download/chapter": (200, epub)])
        let data = try await KavitaClient(baseURL: base, authKey: "key", http: HTTPClient(transport: stub)).downloadChapter(chapterId: 359)
        #expect(data == epub)
        let request = try #require(stub.requests.first)
        #expect(request.url?.query() == "chapterId=359")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "key")
    }

    @Test func seriesPageMetadataSearchAndOneSeries() async throws {
        let stub = StubTransport(routes: [
            "/api/Series/metadata": (200, try fixture("series-metadata.json")),
            "/api/Search/search": (200, try fixture("search.json")),
            "/api/Series/359": (200, try fixture("series.json")),
        ])
        let client = KavitaClient(baseURL: base, authKey: "k", http: HTTPClient(transport: stub))
        let metadata = try await client.seriesMetadata(seriesId: 359)
        #expect(metadata.genreNames == ["Action", "Adventure", "Comedy", "Fantasy", "Slice of Life"])
        #expect(metadata.writerNames == ["山田そら"])
        let summary = try #require(metadata.plainSummary)
        #expect(summary.hasPrefix("空の庭に住む少女") && !summary.contains("<"))
        let found = try await client.search("ソラ")
        #expect(found.first?.name == "そら　ソラ　空　ガーデン")
        #expect(stub.requests[1].url?.query()?.contains("queryString=") == true)
        let series = try await client.series(id: 359)
        #expect(series.pages == 101 && series.libraryId == 4)
    }

    @Test func recentlyAddedSortsByCreatedNewestFirst() async throws {
        let stub = StubTransport(routes: ["/api/Series/v2": (200, try fixture("series-v2.json"))])
        _ = try await KavitaClient(baseURL: base, authKey: "k", http: HTTPClient(transport: stub)).recentlyAdded(libraryId: 3, limit: 12)
        let request = try #require(stub.requests.first)
        #expect(request.url?.query()?.contains("pageSize=12") == true)
        let body = try request.jsonBody()
        let sort = body["sortOptions"] as? [String: Any]
        #expect(sort?["sortField"] as? Int == 2 && sort?["isAscending"] as? Bool == false)
    }

    @Test func decodesServerInfo() async throws {
        let transport = StubTransport(routes: ["/api/Server/server-info-slim": (200, try fixture("server-info-slim.json"))])
        let info = try await KavitaClient(baseURL: base, authKey: "k", http: HTTPClient(transport: transport)).serverInfo()
        #expect(info.kavitaVersion == "0.9.1.7")
        #expect(info.isDocker == true)
    }

    @Test func decodesUserRoles() async throws {
        let transport = StubTransport(routes: ["/api/Account": (200, try fixture("account.json"))])
        let user = try await KavitaClient(baseURL: base, authKey: "k", http: HTTPClient(transport: transport)).currentUser()
        #expect(user.roles.contains("Login"))
    }

    @Test func badKeyIsUnauthorized() async {
        let client = KavitaClient(baseURL: base, authKey: "bad", http: HTTPClient(transport: StubTransport(routes: ["/api/Account": (401, Data())])))
        await #expect(throws: ConnectionError.unauthorized) { try await client.testConnection() }
    }

    @Test func nonKavitaServerIsReported() async {
        let html = Data("<html>hello</html>".utf8)
        let client = KavitaClient(baseURL: base, authKey: "k", http: HTTPClient(transport: StubTransport { _ in (200, html) }))
        await #expect(throws: ConnectionError.notThisService("Expected a Kavita server.")) { try await client.testConnection() }
    }

    @Test func transportFailureIsUnreachable() async {
        let client = KavitaClient(baseURL: base, authKey: "k", http: HTTPClient(transport: StubTransport { _ in
            throw URLError(.cannotConnectToHost)
        }))
        await #expect {
            try await client.testConnection()
        } throws: { error in
            guard case .unreachable = error as? ConnectionError else { return false }
            return (error as? ConnectionError)?.isTransient == true
        }
    }
}
