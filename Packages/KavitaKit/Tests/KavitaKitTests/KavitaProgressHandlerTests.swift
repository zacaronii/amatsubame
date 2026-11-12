import Core
import CoreTestSupport
import Foundation
import KavitaKit
import Testing

@Suite struct KavitaProgressHandlerTests {
    let base = URL(string: "https://kavita.example.ts.net")!
    let payload = KavitaProgressPayload(volumeId: 206, chapterId: 206, pageNum: 5, seriesId: 4, libraryId: 1)

    func job(updatedAt: Date) throws -> OutboxJob {
        OutboxJob(id: 1, kind: .kavitaProgress, coalesceKey: "kavita.chapter.206", payload: try JSONEncoder().encode(payload),
                  state: .inFlight, attempts: 0, lastError: nil, nextAttemptAt: updatedAt, createdAt: updatedAt, updatedAt: updatedAt)
    }

    func handler(_ transport: StubTransport) -> KavitaProgressHandler {
        KavitaProgressHandler { KavitaClient(baseURL: base, authKey: "k", http: HTTPClient(transport: transport)) }
    }

    func progressJSON(_ date: String) -> Data {
        Data(#"{"volumeId":206,"chapterId":206,"pageNum":9,"seriesId":4,"libraryId":1,"bookScrollId":null,"lastModifiedUtc":"\#(date)"}"#.utf8)
    }

    @Test func postsWhenServerIsOlder() async throws {
        let transport = StubTransport(routes: [
            "/api/Reader/get-progress": (200, progressJSON("2026-10-30T00:00:00")),
            "/api/Reader/progress": (200, Data()),
        ])
        try await handler(transport).send(try job(updatedAt: Date(timeIntervalSince1970: 1_793_400_000)), media: [])
        #expect(transport.requests.map { $0.url!.path() } == ["/api/Reader/get-progress", "/api/Reader/progress"])
        #expect(try transport.requests[1].jsonBody()["pageNum"] as? Int == 5)
    }

    @Test func postsWhenServerHasNoProgress() async throws {
        let transport = StubTransport(routes: [
            "/api/Reader/get-progress": (200, progressJSON("0001-01-01T00:00:00")),
            "/api/Reader/progress": (200, Data()),
        ])
        try await handler(transport).send(try job(updatedAt: Date(timeIntervalSince1970: 1_700_000_000)), media: [])
        #expect(transport.requests.count == 2)
    }

    @Test func skipsWhenServerIsNewer() async throws {
        let transport = StubTransport(routes: ["/api/Reader/get-progress": (200, progressJSON("2026-10-31T12:00:00"))])
        try await handler(transport).send(try job(updatedAt: Date(timeIntervalSince1970: 1_793_400_000)), media: [])
        #expect(transport.requests.count == 1)
    }

    @Test func clientErrorsArePermanentButAuthAndOutagesRetry() async throws {
        let date = Date(timeIntervalSince1970: 1_793_400_000)
        let bad = StubTransport(routes: ["/api/Reader/get-progress": (200, progressJSON("0001-01-01T00:00:00")), "/api/Reader/progress": (400, Data())])
        await #expect(throws: OutboxPermanentFailure.self) { try await handler(bad).send(try job(updatedAt: date), media: []) }

        let unauthorized = StubTransport { _ in (401, Data()) }
        await #expect(throws: ConnectionError.unauthorized) { try await handler(unauthorized).send(try job(updatedAt: date), media: []) }

        let down = StubTransport { _ in (503, Data()) }
        await #expect(throws: ConnectionError.server(status: 503)) { try await handler(down).send(try job(updatedAt: date), media: []) }
    }

    @Test func missingSetupRetriesAndCorruptPayloadFails() async throws {
        let date = Date(timeIntervalSince1970: 1_793_400_000)
        let unconfigured = KavitaProgressHandler { nil }
        await #expect(throws: ConnectionError.self) { try await unconfigured.send(try job(updatedAt: date), media: []) }

        var corrupt = try job(updatedAt: date)
        corrupt.payload = Data("{}".utf8)
        await #expect(throws: OutboxPermanentFailure.self) { try await unconfigured.send(corrupt, media: []) }
    }
}

@Suite struct KavitaLibraryRepositoryTests {
    let base = URL(string: "https://kavita.example.ts.net")!

    func fixture(_ name: String) throws -> Data { try Fixture.data(name, in: .module) }

    @Test func refreshCachesLibrariesSeriesAndVolumes() async throws {
        let repository = KavitaLibraryRepository(database: try AppDatabase.inMemory())
        let transport = StubTransport(routes: [
            "/api/Library/libraries": (200, try fixture("libraries.json")),
            "/api/Series/v2": (200, try fixture("series-v2.json")),
            "/api/Series/volumes": (200, try fixture("volumes.json")),
        ])
        let client = KavitaClient(baseURL: base, authKey: "k", http: HTTPClient(transport: transport))

        #expect(try repository.cachedLibraries().isEmpty)
        try await repository.refreshLibraries(using: client)
        #expect(try repository.cachedLibraries().count == 4)

        let series = try await repository.refreshSeries(libraryId: 1, using: client)
        #expect(series.count == 3)
        #expect(try repository.cachedSeries(libraryId: 1).map(\.id) == series.map(\.id))

        let seriesId = series[0].id
        try await repository.refreshVolumes(seriesId: seriesId, using: client)
        let cached = try repository.cachedVolumes(seriesId: seriesId)
        #expect(cached.count == 3)
        #expect(cached.allSatisfy { !$0.chapters.isEmpty })
        #expect(try repository.cachedSeries(id: seriesId)?.name == series[0].name)
    }

    @Test func refreshRemovesSeriesDeletedOnServer() async throws {
        let repository = KavitaLibraryRepository(database: try AppDatabase.inMemory())
        let libraries = try fixture("libraries.json")
        let full = try fixture("series-v2.json")
        let array = try JSONSerialization.jsonObject(with: full) as! [Any]
        let trimmed = try JSONSerialization.data(withJSONObject: Array(array.prefix(1)))

        let first = KavitaClient(baseURL: base, authKey: "k", http: HTTPClient(transport: StubTransport(routes: ["/api/Library/libraries": (200, libraries), "/api/Series/v2": (200, full)])))
        try await repository.refreshLibraries(using: first)
        try await repository.refreshSeries(libraryId: 1, using: first)
        let second = KavitaClient(baseURL: base, authKey: "k", http: HTTPClient(transport: StubTransport(routes: ["/api/Series/v2": (200, trimmed)])))
        #expect(try await repository.refreshSeries(libraryId: 1, using: second).count == 1)
    }
}
