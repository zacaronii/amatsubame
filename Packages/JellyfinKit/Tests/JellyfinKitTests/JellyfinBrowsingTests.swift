import Core
import CoreTestSupport
import Foundation
import JellyfinKit
import Testing

@Suite struct JellyfinBrowsingTests {
    let base = URL(string: "https://jellyfin.example.ts.net")!
    let identity = JellyfinClientIdentity(device: "iPhone", deviceId: "device-1", version: "0.1.0")
    let userId = "00000000000000000000000000000001"

    func fixture(_ name: String) throws -> Data { try Fixture.data(name, in: .module) }

    func client(_ transport: StubTransport, userId: String? = "00000000000000000000000000000001") -> JellyfinClient {
        JellyfinClient(baseURL: base, identity: identity, accessToken: "tok", userId: userId, http: HTTPClient(transport: transport))
    }

    func query(_ request: URLRequest) -> [String: String] {
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    @Test func viewsAreLibraries() async throws {
        let transport = StubTransport(routes: ["/UserViews": (200, try fixture("views.json"))])
        let views = try await client(transport).views()
        #expect(views.map(\.name) == ["Anime", "Movies", "Shows"])
        #expect(views.map(\.collectionType) == ["tvshows", "movies", "tvshows"])
        #expect(query(transport.requests[0])["userId"] == userId)
        #expect(transport.requests[0].value(forHTTPHeaderField: "Authorization")?.hasSuffix(#"Token="tok""#) == true)
    }

    @Test func resumeDecodesPositionAndDates() async throws {
        let transport = StubTransport(routes: ["/UserItems/Resume": (200, try fixture("resume.json"))])
        let item = try #require(try await client(transport).resume().first)
        #expect(item.isEpisode)
        #expect(item.episodeLabel == "S2E5")
        #expect(item.resumePosition == 869.921341)
        #expect(item.userData?.lastPlayedDate == Date(timeIntervalSince1970: 1_896_462_798.455))
        #expect(query(transport.requests[0])["fields"]?.contains("MediaStreams") == true)
    }

    @Test func nextUpBadgesEpisodesWithoutJapanese() async throws {
        let transport = StubTransport(routes: ["/Shows/NextUp": (200, try fixture("next-up.json"))])
        let items = try await client(transport).nextUp()
        // English, Arabic and German only: no badge-worthy Japanese track.
        #expect(items[0].japaneseSubtitle == nil)
        #expect(items[1].japaneseSubtitle?.index == 1)
        // PGS Japanese is skipped in favour of the external SRT.
        #expect(items[2].japaneseSubtitle?.index == 1)
    }

    @Test func seriesSeasonsEpisodesAndItem() async throws {
        let transport = StubTransport(routes: [
            "/Items": (200, try fixture("series.json")),
            "/Shows/S/Seasons": (200, try fixture("seasons.json")),
            "/Shows/S/Episodes": (200, try fixture("episodes.json")),
            "/Items/E": (200, try fixture("item.json")),
        ])
        let jellyfin = client(transport)
        let series = try await jellyfin.libraryItems(libraryId: "L")
        #expect(series.count == 3 && series.allSatisfy { $0.type == "Series" })
        #expect(series[0].userData?.unplayedItemCount == 29)
        #expect(query(transport.requests[0])["parentId"] == "L")

        let seasons = try await jellyfin.seasons(seriesId: "S")
        #expect(seasons.first?.indexNumber == 1)

        let episodes = try await jellyfin.episodes(seriesId: "S", seasonId: "X")
        #expect(episodes.map(\.indexNumber) == [1, 2, 3])
        #expect(query(transport.requests[2])["seasonId"] == "X")
        #expect(episodes[0].hasJapaneseAudio)
        #expect(!series[0].hasJapaneseAudio)
        #expect(query(transport.requests[0])["fields"]?.contains("MediaStreams") == false)

        let first = try await jellyfin.firstEpisode(seriesId: "S")
        #expect(first?.hasJapaneseAudio == true)
        #expect(query(transport.requests[3])["limit"] == "1" && query(transport.requests[3])["fields"] == "MediaStreams")
        _ = try await jellyfin.libraryItems(libraryId: "L", withStreams: true)
        #expect(query(transport.requests[4])["fields"]?.hasSuffix(",MediaStreams") == true)

        let item = try await jellyfin.item(id: "E")
        let source = try #require(item.mediaSources?.first)
        #expect(source.id == "fa4e000000000000000000000000001b")
        #expect(item.japaneseSubtitle?.index == 1)
        #expect(JellyfinSubtitlePicker.english(in: source.mediaStreams ?? [])?.index == 0)
        #expect(item.duration == 1421.045)
    }

    @Test func homeShelvesSearchAndNextUpForASeries() async throws {
        let transport = StubTransport(routes: [
            "/Items": (200, try fixture("series.json")),
            "/Shows/NextUp": (200, try fixture("next-up.json")),
        ])
        let jellyfin = client(transport)
        let latest = try await jellyfin.recentlyAdded(libraryId: "L", limit: 12)
        #expect(latest.count == 3)
        let shelf = query(transport.requests[0])
        #expect(shelf["parentId"] == "L" && shelf["limit"] == "12" && shelf["sortOrder"] == "Descending")
        #expect(shelf["sortBy"]?.hasPrefix("DateLastContentAdded") == true && shelf["includeItemTypes"] == "Series,Movie")
        _ = try await jellyfin.search("example")
        #expect(query(transport.requests[1])["searchTerm"] == "example")
        _ = try await jellyfin.nextUp(seriesId: "S", limit: 1)
        #expect(query(transport.requests[2])["seriesId"] == "S" && query(transport.requests[2])["limit"] == "1")
    }

    @Test func playbackInfoStreamAndSubtitles() async throws {
        let transport = StubTransport(routes: [
            "/Items/E/PlaybackInfo": (200, try fixture("playback-info.json")),
            "/Videos/E/M/Subtitles/1/0/Stream.srt": (200, try fixture("subtitle.srt")),
        ])
        let jellyfin = client(transport)
        let info = try await jellyfin.playbackInfo(itemId: "E")
        #expect(info.playSessionId == "fa4e0000000000000000000000000040")
        #expect(transport.requests[0].httpMethod == "POST")
        #expect(try transport.requests[0].jsonBody()["UserId"] as? String == userId)

        let stream = jellyfin.streamURL(itemId: "E", mediaSourceId: "M", playSessionId: "P")
        #expect(stream.path() == "/Videos/E/stream")
        #expect(query(URLRequest(url: stream)) == ["static": "true", "mediaSourceId": "M", "playSessionId": "P"])
        #expect(!stream.absoluteString.contains("tok"))
        let audio = jellyfin.audioOnlyStreamURL(itemId: "E", mediaSourceId: "M", audioIndex: 2)
        #expect(audio.path() == "/Audio/E/stream")
        #expect(query(URLRequest(url: audio)) == ["container": "ogg", "audioCodec": "opus", "audioChannels": "1",
                                                  "audioSampleRate": "16000", "audioBitRate": "24000", "mediaSourceId": "M",
                                                  "audioStreamIndex": "2"])
        #expect(jellyfin.playbackHeaders["Authorization"]?.hasSuffix(#"Token="tok""#) == true)

        let srt = try await jellyfin.subtitleText(itemId: "E", mediaSourceId: "M", index: 1)
        #expect(srt.contains("-->"))
    }

    @Test func reportsGoToTheRightEndpoint() async throws {
        let transport = StubTransport { _ in (204, Data()) }
        let jellyfin = client(transport)
        for event in [JellyfinProgressPayload.Event.started, .progress, .paused, .unpaused, .stopped] {
            try await jellyfin.report(JellyfinProgressPayload(itemId: "E", mediaSourceId: "M", playSessionId: "P",
                                                              positionTicks: 1_250_000_000, isPaused: event == .paused, event: event))
        }
        #expect(transport.requests.map { $0.url!.path() } == ["/Sessions/Playing", "/Sessions/Playing/Progress", "/Sessions/Playing/Progress",
                                                               "/Sessions/Playing/Progress", "/Sessions/Playing/Stopped"])
        // Pause and resume say so (Playback Reporting and Jellyfin's session state follow them).
        let names = try transport.requests.map { try $0.jsonBody()["EventName"] as? String }
        #expect(names == [nil, "TimeUpdate", "Pause", "Unpause", nil])
        #expect(try transport.requests[2].jsonBody()["IsPaused"] as? Bool == true)
        let body = try transport.requests[4].jsonBody()
        #expect(body["PositionTicks"] as? Int == 1_250_000_000)
        #expect(body["ItemId"] as? String == "E")
        #expect(body["PlaySessionId"] as? String == "P")
    }

    @Test func similarItems() async throws {
        // Shape as Jellyfin 12.3 answers (names and ids replaced).
        let json = #"{"Items":[{"Id":"s1","Name":"Show One","Type":"Series","ImageTags":{"Primary":"t1"}},{"Id":"s2","Name":"Show Two","Type":"Series"}],"TotalRecordCount":2,"StartIndex":0}"#
        let transport = StubTransport(routes: ["/Items/S/Similar": (200, Data(json.utf8))])
        let items = try await client(transport).similar(itemId: "S", limit: 3)
        #expect(items.map(\.name) == ["Show One", "Show Two"])
        #expect(items.first?.imageTags?["Primary"] == "t1")
        let query = URLComponents(url: try #require(transport.requests.first?.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(query.contains(URLQueryItem(name: "limit", value: "3")))
    }

    @Test func onlyTimeUpdatesCoalesce() {
        func payload(_ event: JellyfinProgressPayload.Event) -> JellyfinProgressPayload {
            JellyfinProgressPayload(itemId: "E", mediaSourceId: "M", playSessionId: "P", positionTicks: 0, event: event)
        }
        #expect(payload(.progress).coalesceKey == "jellyfin.item.E.progress")
        #expect([.started, .paused, .unpaused, .stopped].allSatisfy { payload($0).coalesceKey == nil })
    }

    @Test func browsingNeedsSignIn() async {
        let transport = StubTransport { _ in (200, Data()) }
        await #expect(throws: ConnectionError.self) { try await client(transport, userId: nil).views() }
        #expect(transport.requests.isEmpty)
    }

    @Test func subtitlePickerPrefersFullExternalSRT() {
        let streams = [
            JellyfinMediaStream(index: 3, type: "Subtitle", language: "jpn", codec: "PGSSUB", isTextSubtitleStream: false),
            JellyfinMediaStream(index: 4, type: "Subtitle", language: "jpn", codec: "ass", isTextSubtitleStream: true),
            JellyfinMediaStream(index: 5, type: "Subtitle", language: "jpn", codec: "subrip", title: "Signs", isExternal: true, isTextSubtitleStream: true),
            JellyfinMediaStream(index: 6, type: "Subtitle", language: "jpn", codec: "subrip", isTextSubtitleStream: true),
            JellyfinMediaStream(index: 7, type: "Subtitle", language: "jpn", codec: "subrip", isExternal: true, isTextSubtitleStream: true),
        ]
        #expect(JellyfinSubtitlePicker.japanese(in: streams)?.index == 7)
        #expect(JellyfinSubtitlePicker.japanese(in: Array(streams.prefix(4)))?.index == 6)
        #expect(JellyfinSubtitlePicker.japanese(in: Array(streams.prefix(3)))?.index == 4)
        #expect(JellyfinSubtitlePicker.japanese(in: Array(streams.prefix(1))) == nil)
        // The J key's list: every Japanese text track, best first; image tracks left out.
        #expect(JellyfinSubtitlePicker.japaneseTracks(in: streams).map(\.index) == [7, 6, 4, 5])
    }

    @Test func syncReferencesPreferEmbeddedFullTracks() {
        // A typical episode: an external English file, embedded signs, full English, others.
        let streams = [
            JellyfinMediaStream(index: 0, type: "Subtitle", language: "eng", codec: "subrip", isExternal: true, isTextSubtitleStream: true),
            JellyfinMediaStream(index: 2, type: "Audio", language: "jpn", codec: "aac"),
            JellyfinMediaStream(index: 4, type: "Subtitle", language: "eng", codec: "ass", title: "Forced", isTextSubtitleStream: true, isForced: true),
            JellyfinMediaStream(index: 5, type: "Subtitle", language: "deu", codec: "ass", isTextSubtitleStream: true),
            JellyfinMediaStream(index: 6, type: "Subtitle", language: "eng", codec: "ass", isTextSubtitleStream: true),
            JellyfinMediaStream(index: 7, type: "Subtitle", language: "eng", codec: "PGSSUB", isTextSubtitleStream: false),
        ]
        #expect(JellyfinSubtitlePicker.syncReferences(in: streams).map(\.index) == [6, 5, 0])
    }
}

@Suite struct JellyfinProgressHandlerTests {
    let base = URL(string: "https://jellyfin.example.ts.net")!
    let queuedAt = Date(timeIntervalSince1970: 1_793_400_000)
    let payload = JellyfinProgressPayload(itemId: "E", mediaSourceId: "M", playSessionId: "P", positionTicks: 600_000_000, event: .progress)

    func job(_ payload: Data? = nil) throws -> OutboxJob {
        OutboxJob(id: 1, kind: .jellyfinProgress, coalesceKey: self.payload.coalesceKey,
                  payload: try payload ?? JSONEncoder().encode(self.payload), state: .inFlight, attempts: 0, lastError: nil,
                  nextAttemptAt: queuedAt, createdAt: queuedAt, updatedAt: queuedAt)
    }

    func handler(_ transport: StubTransport, now: Date) -> JellyfinProgressHandler {
        let client = JellyfinClient(baseURL: base, identity: JellyfinClientIdentity(device: "d", deviceId: "i", version: "1"),
                                    accessToken: "tok", userId: "U", http: HTTPClient(transport: transport))
        return JellyfinProgressHandler(makeClient: { client }, now: { now })
    }

    func itemJSON(lastPlayed: String?) -> Data {
        let date = lastPlayed.map { #""\#($0)""# } ?? "null"
        return Data(#"{"Id":"E","Name":"Ep","Type":"Episode","UserData":{"PlaybackPositionTicks":0,"LastPlayedDate":\#(date)}}"#.utf8)
    }

    @Test func freshReportIsSentAsIs() async throws {
        let transport = StubTransport { _ in (204, Data()) }
        try await handler(transport, now: queuedAt.addingTimeInterval(5)).send(try job(), media: [])
        #expect(transport.requests.map { $0.url!.path() } == ["/Sessions/Playing/Progress"])
    }

    func payload(_ event: JellyfinProgressPayload.Event, reportedAt: Date? = nil) -> Data {
        try! JSONEncoder().encode(JellyfinProgressPayload(itemId: "E", mediaSourceId: "M", playSessionId: "P",
                                                          positionTicks: 600_000_000, event: event, reportedAt: reportedAt))
    }

    @Test func staleStopIsSentWhenTheServerHasNothingNewer() async throws {
        let transport = StubTransport(routes: [
            "/Items/E": (200, itemJSON(lastPlayed: "2026-10-29T10:00:00.1234567Z")),
            "/Sessions/Playing/Stopped": (204, Data()),
        ])
        try await handler(transport, now: queuedAt.addingTimeInterval(3600)).send(try job(payload(.stopped)), media: [])
        #expect(transport.requests.map { $0.url!.path() } == ["/Items/E", "/Sessions/Playing/Stopped"])
        #expect(try transport.requests[1].jsonBody()["PositionTicks"] as? Int == 600_000_000)
    }

    @Test func staleStopIsDroppedWhenWatchedElsewhereSince() async throws {
        // The iPad, asleep with an old position, mustn't roll back what the iPhone saved since.
        let transport = StubTransport(routes: ["/Items/E": (200, itemJSON(lastPlayed: "2026-11-30T10:00:00Z"))])
        try await handler(transport, now: queuedAt.addingTimeInterval(3600)).send(try job(payload(.stopped)), media: [])
        #expect(transport.requests.map { $0.url!.path() } == ["/Items/E"])
    }

    @Test func staleStartsAndProgressAreDropped() async throws {
        // Sent late, they'd revive a session Jellyfin has closed (and used to become extra stops).
        let transport = StubTransport { _ in (204, Data()) }
        for event in [JellyfinProgressPayload.Event.started, .progress, .paused, .unpaused] {
            try await handler(transport, now: queuedAt.addingTimeInterval(3600)).send(try job(payload(event)), media: [])
        }
        #expect(transport.requests.isEmpty)
    }

    @Test func ageComesFromWhenThePositionWasTaken() async throws {
        // A retried job looks recently updated; the report's own time says it's old.
        let transport = StubTransport { _ in (204, Data()) }
        let late = queuedAt.addingTimeInterval(3600)
        let job = OutboxJob(id: 1, kind: .jellyfinProgress, coalesceKey: nil, payload: payload(.progress, reportedAt: queuedAt),
                            state: .inFlight, attempts: 3, lastError: nil, nextAttemptAt: late, createdAt: queuedAt, updatedAt: late)
        try await handler(transport, now: late.addingTimeInterval(1)).send(job, media: [])
        #expect(transport.requests.isEmpty)
    }

    @Test func tracksAreReported() async throws {
        let transport = StubTransport { _ in (204, Data()) }
        let report = JellyfinProgressPayload(itemId: "E", mediaSourceId: "M", playSessionId: "P", positionTicks: 0,
                                             event: .progress, audioStreamIndex: 2, subtitleStreamIndex: 4)
        try await handler(transport, now: queuedAt).send(try job(try JSONEncoder().encode(report)), media: [])
        let body = try transport.requests[0].jsonBody()
        #expect(body["AudioStreamIndex"] as? Int == 2 && body["SubtitleStreamIndex"] as? Int == 4)
    }

    @Test func failuresClassify() async throws {
        let now = queuedAt.addingTimeInterval(5)
        await #expect(throws: OutboxPermanentFailure.self) {
            try await handler(StubTransport { _ in (400, Data()) }, now: now).send(try job(), media: [])
        }
        await #expect(throws: ConnectionError.unauthorized) {
            try await handler(StubTransport { _ in (401, Data()) }, now: now).send(try job(), media: [])
        }
        await #expect(throws: ConnectionError.server(status: 503)) {
            try await handler(StubTransport { _ in (503, Data()) }, now: now).send(try job(), media: [])
        }
        await #expect(throws: OutboxPermanentFailure.self) {
            try await handler(StubTransport { _ in (204, Data()) }, now: now).send(try job(Data("{}".utf8)), media: [])
        }
        await #expect(throws: ConnectionError.self) {
            try await JellyfinProgressHandler(makeClient: { nil }).send(try job(), media: [])
        }
    }
}

@Suite struct JellyfinUpNextTests {
    func episode(_ id: String, _ season: Int, _ number: Int) -> JellyfinItem {
        var item = JellyfinItem(id: id, name: "Ep \(id)", type: "Episode")
        item.parentIndexNumber = season
        item.indexNumber = number
        return item
    }

    @Test func nextEpisodesCrossSeasonsAndEndAtTheLast() {
        let list = [episode("a", 1, 1), episode("b", 1, 2), episode("c", 2, 1)]
        #expect(JellyfinUpNext.episodes(after: "b", in: list).map(\.id) == ["c"])
        #expect(JellyfinUpNext.episodes(after: "a", in: list).map(\.id) == ["b", "c"])
        #expect(JellyfinUpNext.episodes(after: "c", in: list).isEmpty)
        #expect(JellyfinUpNext.episodes(after: "zz", in: list).isEmpty)
        #expect(JellyfinUpNext.episode(before: "c", in: list)?.id == "b")
        #expect(JellyfinUpNext.episode(before: "a", in: list) == nil)
        #expect(JellyfinUpNext.episode(before: "zz", in: list) == nil)
    }

    @Test func offeredAtTheCreditsElseNearTheEnd() {
        #expect(JellyfinUpNext.offerTime(duration: 1420, creditsStart: 1330) == 1330)
        #expect(JellyfinUpNext.offerTime(duration: 1420, creditsStart: nil) == 1400)
        #expect(JellyfinUpNext.offerTime(duration: 0, creditsStart: nil) == nil)
        #expect(JellyfinUpNext.offerTime(duration: 40, creditsStart: nil) == nil)
    }

    @Test func suggestionsPreferTheSameLibraryAndSkipHiddenOnes() {
        let similar = ["dub", "anime1", "hidden", "anime2", "anime3"].map { JellyfinItem(id: $0, name: $0, type: "Series") }
        let libraries = ["dub": "shows", "anime1": "anime", "hidden": "secret", "anime2": "anime", "anime3": "anime"]
        let picked = JellyfinUpNext.suggestions(similar, libraries: libraries, currentLibrary: "anime", hidden: ["secret"])
        #expect(picked.map(\.id) == ["anime1", "anime2", "anime3"])
        let fewer = JellyfinUpNext.suggestions(Array(similar.prefix(3)), libraries: libraries, currentLibrary: "anime", hidden: ["secret"])
        #expect(fewer.map(\.id) == ["anime1", "dub"])
    }
}
