import AudiobookshelfKit
import Core
import CoreTestSupport
import Foundation
import Synchronization
import Testing

/// Up Next against a fake Audiobookshelf that behaves as 2.38.0 did on the test account:
/// playlists per library, a reorder must keep the same items, and a playlist whose last item
/// goes is deleted.
@Suite struct AudiobookshelfUpNextTests {
    let base = URL(string: "https://abs.example.ts.net")!
    let date = Date(timeIntervalSince1970: 1_795_651_200)

    final class FakeServer: Sendable {
        struct Playlist { var name: String; var library: String; var items: [[String: String]] }
        let playlists = Mutex<[String: Playlist]>([:])
        let log = Mutex<[String]>([])
        let next = Mutex(1)
        /// Paths that answer 404 this many times (a playlist deleted under the job).
        let vanish = Mutex<[String: Int]>([:])

        func json(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object) }

        func playlistJSON(_ id: String, _ p: Playlist) -> [String: Any] {
            ["id": id, "name": p.name, "libraryId": p.library, "userId": "u", "description": NSNull(), "lastUpdate": 1, "createdAt": 1,
             "items": p.items.map { ["libraryItemId": $0["libraryItemId"]!, "episodeId": $0["episodeId"]!] }]
        }

        func handle(_ request: URLRequest) throws -> (Int, Data) {
            let path = request.url!.path(), method = request.httpMethod ?? "GET"
            log.withLock { $0.append("\(method) \(path)") }
            let body = (request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
            let items = (body["items"] as? [[String: String]]) ?? []
            if vanish.withLock({ v in (v[path] ?? 0) > 0 ? { v[path]! -= 1; return true }() : false }) { return (404, Data("Playlist not found".utf8)) }
            let parts = path.split(separator: "/").map(String.init)
            if method == "GET", parts.count == 4, parts[1] == "libraries", parts[3] == "playlists" {
                let found = playlists.withLock { $0.filter { $0.value.library == parts[2] }.map { playlistJSON($0.key, $0.value) } }
                return (200, json(["results": found, "total": found.count, "limit": 0, "page": 0]))
            }
            if method == "POST", parts == ["api", "playlists"] {
                let id = next.withLock { n in defer { n += 1 }; return "pl-\(n)" }
                let p = Playlist(name: body["name"] as! String, library: body["libraryId"] as! String, items: items)
                playlists.withLock { $0[id] = p }
                return (200, json(playlistJSON(id, p)))
            }
            guard parts.count >= 3, parts[1] == "playlists" else { return (404, Data()) }
            let id = parts[2]
            return try playlists.withLock { all -> (Int, Data) in
                guard var p = all[id] else { return (404, Data("Playlist not found".utf8)) }
                switch (method, parts.count > 3 ? parts[3] : "", parts.count > 4 ? parts[4] : "") {
                case ("GET", "", _): return (200, json(playlistJSON(id, p)))
                case ("POST", "batch", "add"): p.items += items.filter { !p.items.contains($0) }
                case ("POST", "batch", "remove"):
                    p.items.removeAll { items.contains($0) }
                    if p.items.isEmpty { all[id] = nil; return (200, Data("{}".utf8)) }
                case ("PATCH", "", _):
                    guard Set(items) == Set(p.items), items.count == p.items.count else { return (400, Data("Invalid playlist items. Length mismatch".utf8)) }
                    p.items = items
                default: return (404, Data())
                }
                all[id] = p
                return (200, json(playlistJSON(id, p)))
            }
        }

        func items(_ id: String) -> [String]? { playlists.withLock { $0[id]?.items.map { $0["episodeId"]! } } }
    }

    func setUp() throws -> (FakeServer, AudiobookshelfUpNextHandler, UpNextStore) {
        let server = FakeServer()
        let transport = StubTransport { try server.handle($0) }
        let secrets = InMemorySecretStore()
        try secrets.setSecret("tok", for: .audiobookshelfToken)
        let client = AudiobookshelfClient(baseURL: base, tokens: AudiobookshelfTokens(secrets: secrets), http: HTTPClient(transport: transport))
        let store = UpNextStore(database: try AppDatabase.inMemory())
        return (server, AudiobookshelfUpNextHandler(store: store, makeClient: { client }), store)
    }

    func item(_ episode: String) -> UpNextItem { UpNextItem(itemId: "show", episodeId: episode, title: episode, showTitle: "番組") }

    func send(_ handler: AudiobookshelfUpNextHandler, _ episodes: [String]) async throws {
        let payload = AudiobookshelfUpNextPayload(libraryId: "lib", items: episodes.map(item))
        try await handler.send(OutboxJob(id: 1, kind: .audiobookshelfUpNext, coalesceKey: payload.coalesceKey, payload: try JSONEncoder().encode(payload),
                                         state: .inFlight, attempts: 0, lastError: nil, nextAttemptAt: date, createdAt: date, updatedAt: date), media: [])
    }

    @Test func decodesPlaylists() throws {
        let playlist = try JSONDecoder().decode(AudiobookshelfPlaylist.self, from: try fixture("playlist.json"))
        #expect(playlist.name == "Up Next" && playlist.items.map(\.episodeId) == ["ep-3", "ep-2", "ep-9"])
        #expect(playlist.items.first?.title == "Episode three" && playlist.items.last?.showTitle == "Sample Show B")
        let sent = try JSONSerialization.jsonObject(with: JSONEncoder().encode(playlist.items[0])) as? [String: String]
        #expect(sent == ["libraryItemId": "show-a", "episodeId": "ep-3"], "only the ids go back")
        struct Page: Decodable { var results: [AudiobookshelfPlaylist] }
        #expect(try JSONDecoder().decode(Page.self, from: try fixture("library-playlists.json")).results.map(\.name) == ["Favourites", "Up Next"])
    }

    @Test func makesThePlaylistThenAddsRemovesAndOrders() async throws {
        let (server, handler, store) = try setUp()
        try await send(handler, ["a", "b"])
        let id = try #require(try store.playlistId(libraryId: "lib"))
        #expect(server.items(id) == ["a", "b"])
        // b played (out), c and d added, d first: added before removed, then ordered.
        server.log.withLock { $0.removeAll() }
        try await send(handler, ["d", "a", "c"])
        #expect(server.items(id) == ["d", "a", "c"])
        let calls = server.log.withLock { $0 }.filter { !$0.hasPrefix("GET") }
        #expect(calls == ["POST /api/playlists/\(id)/batch/add", "POST /api/playlists/\(id)/batch/remove", "PATCH /api/playlists/\(id)"])
        // Nothing to change: only a look.
        server.log.withLock { $0.removeAll() }
        try await send(handler, ["d", "a", "c"])
        #expect(server.log.withLock { $0 }.allSatisfy { $0.hasPrefix("GET") })
    }

    /// The whole queue replaced: the new items go in first, so the playlist never empties
    /// (which would delete it).
    @Test func replacingEverythingKeepsThePlaylist() async throws {
        let (server, handler, store) = try setUp()
        try await send(handler, ["a"])
        let id = try #require(try store.playlistId(libraryId: "lib"))
        try await send(handler, ["x", "y"])
        let kept = try store.playlistId(libraryId: "lib")
        #expect(server.items(id) == ["x", "y"] && kept == id)
    }

    @Test func theUsersOwnUpNextIsUsed() async throws {
        let (server, handler, store) = try setUp()
        server.playlists.withLock { $0["mine"] = .init(name: "Up Next", library: "lib", items: [["libraryItemId": "show", "episodeId": "old"]]) }
        server.playlists.withLock { $0["other"] = .init(name: "Favourites", library: "lib", items: []) }
        try await send(handler, ["a"])
        let used = try store.playlistId(libraryId: "lib")
        #expect(used == "mine" && server.items("mine") == ["a"])
        #expect(server.playlists.withLock { $0.count } == 2, "no second Up Next")
    }

    @Test func emptiedTheServerDeletesItAndTheIdGoes() async throws {
        let (server, handler, store) = try setUp()
        try await send(handler, ["a"])
        try await send(handler, [])
        let gone = try store.playlistId(libraryId: "lib")
        #expect(server.playlists.withLock { $0.isEmpty } && gone == nil)
        try await send(handler, [])
        #expect(server.playlists.withLock { $0.isEmpty }, "nothing made for an empty queue")
    }

    /// Deleted elsewhere: made again once; deleted under the job twice, it gives up for good.
    @Test func deletedElsewhereIsMadeAgainOnceNotInALoop() async throws {
        let (server, handler, store) = try setUp()
        try await send(handler, ["a"])
        let id = try #require(try store.playlistId(libraryId: "lib"))
        server.playlists.withLock { $0[id] = nil }
        try await send(handler, ["a", "b"])
        let again = try #require(try store.playlistId(libraryId: "lib"))
        #expect(again != id && server.items(again) == ["a", "b"])
        // Vanishing under every attempt (the add answers 404 twice).
        server.vanish.withLock { $0["/api/playlists/\(again)/batch/add"] = 2 }
        await #expect(throws: OutboxPermanentFailure.self) { try await send(handler, ["a", "b", "c"]) }
    }
}
