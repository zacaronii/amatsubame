import Core
import CoreTestSupport
import Foundation
import JimakuKit
import Testing
import ZIPFoundation

/// Fixtures follow Jimaku's published schema (`/api/openapi.json`); the mapping one is recorded.
@Suite struct JimakuClientTests {
    func fixture(_ name: String) throws -> Data { try Fixture.data(name, in: .module) }

    func query(_ request: URLRequest) -> [String: String] {
        Dictionary(uniqueKeysWithValues: (URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .map { ($0.name, $0.value ?? "") })
    }

    @Test func searchesByAnilistIdWithKeyAndUserAgent() async throws {
        let transport = StubTransport(routes: ["/api/entries/search": (200, try fixture("search.json"))])
        let entries = try await JimakuClient(apiKey: "key", http: HTTPClient(transport: transport)).search(anilistId: 150672)
        #expect(entries.map(\.japaneseName) == ["【推しの子】"])
        #expect(entries[0].anilistId == 150672 && entries[0].flags?.anime == true)
        let request = try #require(transport.requests.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "key")
        #expect(request.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("Miru/") == true)
        #expect(query(request) == ["anime": "true", "anilist_id": "150672"])
    }

    @Test func listsAnEpisodesFilesAndDownloads() async throws {
        let transport = StubTransport { request in
            if request.url!.path().hasSuffix("/files") { return (200, try fixture("files.json")) }
            return (200, Data("1\n00:00:01,000 --> 00:00:02,000\nあ\n".utf8))
        }
        let client = JimakuClient(apiKey: "key", http: HTTPClient(transport: transport))
        let files = try await client.files(entryId: 1234, episode: 6)
        #expect(files.map(\.name) == ["推しの子 #06.srt", "Oshi no Ko 06.ass"])
        #expect(query(transport.requests[0]) == ["episode": "6"])
        #expect(transport.requests[0].url!.path() == "/api/entries/1234/files")
        let data = try await client.download(files[0])
        #expect(String(decoding: data, as: UTF8.self).contains("あ"))
        #expect(transport.requests[1].url == files[0].url)
    }

    @Test func wrongKeyIsUnauthorized() async throws {
        let transport = StubTransport { _ in (401, Data(#"{"error":"unauthorized","code":401}"#.utf8)) }
        await #expect(throws: ConnectionError.unauthorized) {
            try await JimakuClient(apiKey: "bad", http: HTTPClient(transport: transport)).search(query: "Oshi no Ko")
        }
    }

    @Test func mapsAniDBToAniList() async throws {
        let transport = StubTransport(routes: ["/api/v2/ids": (200, try fixture("anidb-ids.json"))])
        let mapper = AnimeIdMapper(http: HTTPClient(transport: transport))
        #expect(try await mapper.anilistId(anidbId: 17449) == 150672)
        #expect(query(transport.requests[0]) == ["source": "anidb", "id": "17449"])
        let unknown = AnimeIdMapper(http: HTTPClient(transport: StubTransport { _ in (200, Data("null".utf8)) }))
        #expect(try await unknown.anilistId(anidbId: 1) == nil)
    }

    @Test func zipsListTheirSubtitles() throws {
        let archive = try Archive(accessMode: .create)
        for (name, text) in [("Show 02.srt", "b"), ("Show 01.ass", "a"), ("readme.txt", "x"), ("__MACOSX/._Show 01.ass", "junk")] {
            let data = Data(text.utf8)
            try archive.addEntry(with: name, type: .file, uncompressedSize: Int64(data.count)) { position, size in
                data.subdata(in: Int(position)..<Int(position) + size)
            }
        }
        let members = try JimakuArchive.subtitles(in: try #require(archive.data))
        #expect(members.map(\.name) == ["Show 01.ass", "Show 02.srt"])
        #expect(members[0].data == Data("a".utf8))
        #expect(JimakuFileKind(fileName: "x.RAR") == .unsupported(".rar"))
        #expect(JimakuFileKind(fileName: "x.zip") == .zip)
    }
}
