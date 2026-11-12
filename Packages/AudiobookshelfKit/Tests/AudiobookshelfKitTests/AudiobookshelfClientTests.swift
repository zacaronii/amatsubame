import AudiobookshelfKit
import Core
import CoreTestSupport
import Foundation
import Testing

func fixture(_ name: String) throws -> Data { try Fixture.data(name, in: .module) }

@Suite struct AudiobookshelfClientTests {
    let base = URL(string: "https://abs.example.ts.net")!

    func client(_ transport: StubTransport, token: String? = "tok", refresh: String? = nil) throws -> (AudiobookshelfClient, InMemorySecretStore) {
        let secrets = InMemorySecretStore()
        if let token { try secrets.setSecret(token, for: .audiobookshelfToken) }
        if let refresh { try secrets.setSecret(refresh, for: .audiobookshelfRefreshToken) }
        return (AudiobookshelfClient(baseURL: base, tokens: AudiobookshelfTokens(secrets: secrets), http: HTTPClient(transport: transport)), secrets)
    }

    @Test func statusIdentifiesTheServer() async throws {
        let transport = StubTransport(routes: ["/status": (200, try fixture("status.json"))])
        #expect(try await client(transport).0.status().serverVersion == "2.36.1")
        let other = StubTransport(routes: ["/status": (200, Data(#"{"app":"jellyfin","serverVersion":"1"}"#.utf8))])
        await #expect(throws: ConnectionError.notThisService("Expected an Audiobookshelf server.")) { try await client(other).0.status() }
    }

    @Test func loginAsksForTokens() async throws {
        let transport = StubTransport(routes: ["/login": (200, try fixture("login.json"))])
        let user = try await AudiobookshelfClient(baseURL: base, http: HTTPClient(transport: transport)).login(username: "listener", password: "pw")
        #expect(user.accessToken == "REDACTED-access" && user.refreshToken == "REDACTED-refresh")
        let request = try #require(transport.requests.first)
        #expect(request.httpMethod == "POST" && request.value(forHTTPHeaderField: "x-return-tokens") == "true")
        #expect(try request.jsonBody()["username"] as? String == "listener")
    }

    @Test func decodesLibrariesShowsAndEpisodes() async throws {
        let transport = StubTransport(routes: [
            "/api/libraries": (200, try fixture("libraries.json")),
            "/items": (200, try fixture("library-items.json")),
            "/recent-episodes": (200, try fixture("recent-episodes.json")),
            "/api/me/items-in-progress": (200, try fixture("items-in-progress.json")),
            "/api/me": (200, try fixture("me.json")),
        ])
        let (client, _) = try client(transport)
        let libraries = try await client.libraries()
        #expect(libraries.map(\.mediaType) == [.book, .podcast, .book])
        let shows = try await client.items(libraryId: "lib", pageSize: 3)
        #expect(shows.first?.title == "Sample Show A" && (shows.first?.media.numEpisodes ?? 0) > 0)
        let recent = try await client.recentEpisodes(libraryId: "lib", limit: 3)
        #expect(recent.count == 3 && recent.allSatisfy { $0.podcast != nil && $0.audioFile?.ino.isEmpty == false })
        // The extension comes from the file name, never the "MP2/3 (…)" format description.
        #expect(recent.allSatisfy { $0.audioFile?.fileExtension == "mp3" })
        let inProgress = try await client.itemsInProgress()
        #expect(inProgress.first?.recentEpisode != nil)
        let me = try await client.me()
        #expect(me.mediaProgress.allSatisfy { $0.episodeId != nil })
        #expect(transport.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer tok" })
    }

    @Test func expandedItemHasItsEpisodes() async throws {
        let transport = StubTransport(routes: ["/api/items/show": (200, try fixture("item.json"))])
        let item = try await client(transport).0.item(id: "show")
        let episode = try #require(item.media.episodes?.first)
        #expect(episode.length ?? 0 > 0 && episode.publishedDate != nil)
        #expect(transport.requests.first?.url?.query() == "expanded=1")
    }

    @Test func expiredTokenIsRefreshedOnce() async throws {
        let transport = StubTransport { request in
            switch request.url?.path() {
            case "/auth/refresh": (200, try fixture("login.json"))
            case "/api/libraries": request.value(forHTTPHeaderField: "Authorization") == "Bearer REDACTED-access"
                ? (200, try fixture("libraries.json")) : (401, Data())
            default: (404, Data())
            }
        }
        let (client, secrets) = try client(transport, token: "old", refresh: "r1")
        #expect(try await client.libraries().count == 3)
        #expect(try secrets.secret(for: .audiobookshelfToken) == "REDACTED-access")
        #expect(try secrets.secret(for: .audiobookshelfRefreshToken) == "REDACTED-refresh")
        #expect(transport.requests.map { $0.url!.path() } == ["/api/libraries", "/auth/refresh", "/api/libraries"])
        #expect(transport.requests[1].value(forHTTPHeaderField: "x-refresh-token") == "r1")
    }

    @Test func anAPIKeyWithoutRefreshStaysUnauthorized() async throws {
        let transport = StubTransport { _ in (401, Data()) }
        await #expect(throws: ConnectionError.unauthorized) { try await client(transport).0.libraries() }
        #expect(transport.requests.count == 1)
    }

    @Test func signedMediaRequests() async throws {
        let (client, _) = try client(StubTransport { _ in (200, Data()) })
        let audio = try await client.audioRequest(itemId: "show", ino: "123")
        #expect(audio.url?.path() == "/api/items/show/file/123")
        #expect(audio.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        #expect(audio.url?.query() == nil)
        #expect(try await client.coverRequest(itemId: "show").url?.query() == "width=400")
    }

    /// A JWT whose payload says when it runs out (header and signature don't matter here).
    func jwt(expiring date: Date) -> String {
        let payload = Data(#"{"exp":\#(Int(date.timeIntervalSince1970))}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
        return "header.\(payload).signature"
    }

    @Test func aStreamGetsATokenThatLasts() async throws {
        let transport = StubTransport { request in
            request.url?.path() == "/auth/refresh" ? (200, try fixture("login.json")) : (404, Data())
        }
        let (client, _) = try client(transport, token: jwt(expiring: .now.addingTimeInterval(60)), refresh: "r1")
        let audio = try await client.audioRequest(itemId: "show", ino: "123")
        #expect(audio.value(forHTTPHeaderField: "Authorization") == "Bearer REDACTED-access")
        #expect(transport.requests.map { $0.url!.path() } == ["/auth/refresh"])
    }

    @Test func aTokenWithTimeLeftIsKept() async throws {
        let token = jwt(expiring: .now.addingTimeInterval(3600))
        let transport = StubTransport { _ in (404, Data()) }
        let (client, _) = try client(transport, token: token, refresh: "r1")
        #expect(try await client.audioRequest(itemId: "show", ino: "123").value(forHTTPHeaderField: "Authorization") == "Bearer \(token)")
        #expect(transport.requests.isEmpty)
    }
}

@Suite struct AudiobookshelfProgressHandlerTests {
    let base = URL(string: "https://abs.example.ts.net")!
    let date = Date(timeIntervalSince1970: 1_793_400_000)

    func job(_ payload: AudiobookshelfProgressPayload) throws -> OutboxJob {
        OutboxJob(id: 1, kind: .audiobookshelfProgress, coalesceKey: payload.coalesceKey, payload: try JSONEncoder().encode(payload),
                  state: .inFlight, attempts: 0, lastError: nil, nextAttemptAt: date, createdAt: date, updatedAt: date)
    }

    func handler(_ transport: StubTransport, now: Date) throws -> AudiobookshelfProgressHandler {
        let secrets = InMemorySecretStore()
        try secrets.setSecret("tok", for: .audiobookshelfToken)
        let client = AudiobookshelfClient(baseURL: base, tokens: AudiobookshelfTokens(secrets: secrets), http: HTTPClient(transport: transport))
        return AudiobookshelfProgressHandler(makeClient: { client }, now: { now })
    }

    func payload(at time: Date) -> AudiobookshelfProgressPayload {
        AudiobookshelfProgressPayload(itemId: "show", episodeId: "ep", currentTime: 600, duration: 1800, isFinished: false, reportedAt: time)
    }

    @Test func sendsThePosition() async throws {
        let transport = StubTransport { _ in (200, Data()) }
        try await handler(transport, now: date).send(try job(payload(at: date)), media: [])
        let request = try #require(transport.requests.first)
        #expect(request.httpMethod == "PATCH" && request.url?.path() == "/api/me/progress/show/ep")
        let body = try request.jsonBody()
        #expect(body["currentTime"] as? Double == 600 && body["duration"] as? Double == 1800)
        #expect(abs((body["progress"] as? Double ?? 0) - 1.0 / 3) < 0.001 && body["isFinished"] as? Bool == false)
    }

    @Test func aLatePositionLosesToANewerOneOnTheServer() async throws {
        let newer = date.addingTimeInterval(60).timeIntervalSince1970 * 1000
        let transport = StubTransport { request in
            request.httpMethod == "GET"
                ? (200, Data(#"{"libraryItemId":"show","episodeId":"ep","duration":1800,"progress":0.5,"currentTime":900,"isFinished":false,"lastUpdate":\#(newer)}"#.utf8))
                : (200, Data())
        }
        try await handler(transport, now: date.addingTimeInterval(3600)).send(try job(payload(at: date)), media: [])
        #expect(transport.requests.map(\.httpMethod) == ["GET"])
    }

    @Test func aLatePositionStillGoesWhenItIsNewest() async throws {
        let transport = StubTransport { request in request.httpMethod == "GET" ? (404, Data()) : (200, Data()) }
        try await handler(transport, now: date.addingTimeInterval(3600)).send(try job(payload(at: date)), media: [])
        #expect(transport.requests.map(\.httpMethod) == ["GET", "PATCH"])
    }

    @Test func rejectedIsPermanent() async throws {
        let transport = StubTransport { _ in (400, Data()) }
        await #expect(throws: OutboxPermanentFailure.self) { try await handler(transport, now: date).send(try job(payload(at: date)), media: []) }
    }
}

@Suite struct AudiobookshelfBookTests {
    let base = URL(string: "https://abs.example.ts.net")!

    @Test func decodesABookWithChaptersAndTracks() async throws {
        let transport = StubTransport(routes: ["/api/items/book-1": (200, try fixture("book.json")),
                                               "/api/me/progress/book-1": (200, Data(#"{"libraryItemId":"book-1","episodeId":null,"duration":23652.2,"progress":0.17,"currentTime":4069,"isFinished":false,"lastUpdate":1793900000000}"#.utf8))])
        let secrets = InMemorySecretStore()
        try secrets.setSecret("tok", for: .audiobookshelfToken)
        let client = AudiobookshelfClient(baseURL: base, tokens: AudiobookshelfTokens(secrets: secrets), http: HTTPClient(transport: transport))
        let book = try await client.item(id: "book-1")
        #expect(book.isBook && book.title == "テストの本")
        #expect(book.media.metadata.authorName == "著者" && book.media.metadata.narratorName == "朗読者")
        #expect(book.media.chapters?.map(\.title) == ["第0章", "第1章", "第2章"])
        #expect(book.media.tracks?.first?.ino == "310" && book.media.tracks?.first?.startOffset == 0)
        #expect((book.media.duration ?? 0) > 23_000)
        let whole = try #require(AudiobookshelfEpisode.wholeBook(book))
        #expect(whole.key == "book-1" && whole.audioFile?.ino == "310" && whole.audioFile?.fileExtension == "m4a")
        #expect(whole.length == book.media.duration && whole.title == "テストの本")
        // A book's progress has no episode: the key and the path are the item alone.
        let progress = try #require(try await client.progress(itemId: "book-1", episodeId: ""))
        #expect(progress.key == "book-1" && AudiobookshelfProgress.key(itemId: "book-1", episodeId: "") == "book-1")
        try await client.updateProgress(itemId: "book-1", episodeId: "", .init(currentTime: 10, duration: 100, isFinished: false))
        #expect(transport.requests.last?.url?.path() == "/api/me/progress/book-1" && transport.requests.last?.httpMethod == "PATCH")
    }
}

@Suite struct KakuClientTests {
    let base = URL(string: "https://kaku.example.ts.net")!

    func client(_ transport: StubTransport) -> KakuClient { KakuClient(baseURL: base, token: "kt", http: HTTPClient(transport: transport)) }

    @Test func transcriptReadyPendingOrMissing() async throws {
        let transport = StubTransport { request in
            switch request.url?.path() {
            case "/transcripts/show/ep1": (200, try fixture("kaku-transcript.json"))
            case "/transcripts/show/ep2": (202, try fixture("kaku-job.json"))
            default: (404, Data(#"{"detail":"none"}"#.utf8))
            }
        }
        let client = client(transport)
        guard case .ready(let transcript) = try await client.transcript(itemId: "show", episodeId: "ep1") else { Issue.record("not ready"); return }
        #expect(transcript.sentences.map(\.text) == ["それでは、本編をどうぞ。", "よろしくお願いします。"])
        #expect(transcript.sentences[0].words[1].start == 26.5 && transcript.source.fingerprint == "11:22:33.0")
        guard case .pending(let job) = try await client.transcript(itemId: "show", episodeId: "ep2") else { Issue.record("not pending"); return }
        #expect(job.state == .queued && job.position == 1)
        #expect(try await client.transcript(itemId: "show", episodeId: "ep3") == .missing)
        #expect(transport.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer kt" })
    }

    @Test func requestsAJobAndReadsStatuses() async throws {
        let transport = StubTransport { request in
            switch request.url?.path() {
            case "/jobs": (202, try fixture("kaku-job.json"))
            case "/transcripts/status": (200, Data(#"{"statuses":{"show/ep1":"done","show/ep2":"queued","show/ep3":"missing"}}"#.utf8))
            default: (404, Data())
            }
        }
        let client = client(transport)
        #expect(try await client.requestJob(itemId: "show", episodeId: "ep2")?.state == .queued)
        #expect(try transport.requests[0].jsonBody()["episodeId"] as? String == "ep2")
        let statuses = try await client.status([("show", "ep1"), ("show", "ep2"), ("show", "ep3")])
        #expect(statuses == ["show/ep1": .done, "show/ep2": .queued, "show/ep3": .missing])
        let sent = try transport.requests[1].jsonBody()["episodes"] as? [[String: String]]
        #expect(sent?.count == 3 && sent?.first?["itemId"] == "show")
    }

    @Test func booksAndClipsUseTheItemAlone() async throws {
        let transport = StubTransport { request in
            switch request.url?.path() {
            case "/transcripts/book-1": (200, try fixture("kaku-transcript.json"))
            case "/clips/book-1", "/clips/show/ep1": (200, Data("m4a".utf8))
            default: (404, Data())
            }
        }
        let client = client(transport)
        guard case .ready = try await client.transcript(itemId: "book-1", episodeId: "") else { Issue.record("not ready"); return }
        #expect(try await client.clip(itemId: "book-1", episodeId: "", start: 99.75, end: 106.25) == Data("m4a".utf8))
        let query = try #require(transport.requests.last?.url?.query())
        #expect(query == "start=99.750&end=106.250")
        #expect(try await client.clip(itemId: "show", episodeId: "ep1", start: 1, end: 2) == Data("m4a".utf8))
    }

    @Test func jellyfinSubtitlesOnRequest() async throws {
        let transport = StubTransport { request in
            switch request.url?.path() {
            case "/jellyfin/jobs": (200, try fixture("kaku-jellyfin-jobs.json"))
            case "/jellyfin/transcripts/jf-1": (200, Data("1\n00:00:09,010 --> 00:00:12,270\nついに。\n".utf8))
            case "/jellyfin/transcripts/jf-2": (202, Data(#"{"itemId":"jf-2","state":"running","progress":0.05,"error":null,"position":0}"#.utf8))
            case "/jellyfin/transcripts/status": (200, Data(#"{"statuses":{"jf-1":"done","jf-2":"running"}}"#.utf8))
            default: (404, Data())
            }
        }
        let client = client(transport)
        let jobs = try await client.requestJellyfin(["jf-1", "jf-2", "jf-3"])
        #expect(jobs.map(\.state) == [.done, .queued, .unavailable])
        #expect(jobs[1].position == 0 && jobs[2].error == "This episode has no Japanese audio track.")
        #expect(try transport.requests[0].jsonBody()["itemIds"] as? [String] == ["jf-1", "jf-2", "jf-3"])
        guard case .ready(let srt) = try await client.jellyfinSubtitles(itemId: "jf-1") else { Issue.record("not ready"); return }
        #expect(srt.hasPrefix("1\n00:00:09,010"))
        #expect(transport.requests.last?.url?.query() == "format=srt")
        guard case .pending(let job) = try await client.jellyfinSubtitles(itemId: "jf-2") else { Issue.record("not pending"); return }
        #expect(job.state == .running && job.progress == 0.05)
        #expect(try await client.jellyfinSubtitles(itemId: "jf-9") == .missing)
        #expect(try await client.jellyfinStatus(["jf-1", "jf-2"]) == ["jf-1": .done, "jf-2": .running])
    }

    @Test func wrongTokenIsUnauthorized() async throws {
        let transport = StubTransport { _ in (401, Data()) }
        await #expect(throws: ConnectionError.unauthorized) { try await client(transport).transcript(itemId: "a", episodeId: "b") }
    }
}
