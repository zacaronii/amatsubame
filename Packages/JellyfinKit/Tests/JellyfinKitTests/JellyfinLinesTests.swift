import Core
import CoreTestSupport
import Foundation
import JellyfinKit
import Testing

@Suite struct JellyfinLinesTests {
    let base = URL(string: "https://jellyfin.example.ts.net")!
    let userId = "00000000000000000000000000000001"

    func fixture(_ name: String) throws -> Data { try Fixture.data(name, in: .module) }

    func client(_ transport: StubTransport, deviceId: String = "this-device") -> JellyfinClient {
        JellyfinClient(baseURL: base, identity: JellyfinClientIdentity(device: "iPhone", deviceId: deviceId, version: "1"),
                       accessToken: "tok", userId: userId, http: HTTPClient(transport: transport))
    }

    func query(_ request: URLRequest) -> [String: String] {
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    @Test func playedItemsAreNewestFirstPerLibrary() async throws {
        let transport = StubTransport(routes: ["/Items": (200, try fixture("history.json"))])
        let page = try await client(transport).playedItems(libraryId: "L", startIndex: 50, limit: 25)
        #expect(page.items.map(\.name) == ["First Day", "The Year That's Gone", "Late Night Show"])
        #expect(page.totalRecordCount == 38)
        let q = query(transport.requests[0])
        #expect(q["parentId"] == "L" && q["filters"] == "IsPlayed" && q["sortBy"] == "DatePlayed" && q["startIndex"] == "50")
    }

    @Test func libraryOfAnItemIsItsCollectionFolder() async throws {
        let transport = StubTransport(routes: ["/Items/E/Ancestors": (200, try fixture("ancestors.json"))])
        #expect(try await client(transport).libraryId(of: "E") == "fa4e0000000000000000000000000012")
    }

    @Test func sessionsAreOtherDevicesOfThisUser() async throws {
        let transport = StubTransport(routes: ["/Sessions": (200, try fixture("sessions.json"))])
        let sessions = try await client(transport).sessions()
        let session = try #require(sessions.first)
        #expect(session.deviceName == "Chrome")
        #expect(session.nowPlayingItem?.seriesName == "Example Romance Show")
        #expect(session.isPaused)
        #expect(session.playState?.mediaSourceId == "fa4e0000000000000000000000000034")
        #expect(session.supportsRemoteControl == true)
        // Japanese audio is Jellyfin stream 2; one external subtitle comes first, so FFmpeg's 1.
        #expect(session.ffmpegAudioIndex == 1)
        #expect(query(transport.requests[0])["activeWithinSeconds"] != nil)

        // The same device as this app is left out.
        let own = StubTransport(routes: ["/Sessions": (200, try fixture("sessions.json"))])
        #expect(try await client(own, deviceId: "web-device-1").sessions().isEmpty)
    }

    @Test func liveClockKeepsTheBestReadingAndAdvances() {
        let start = Date(timeIntervalSince1970: 1_000)
        var clock = LiveClock()
        clock.observe(position: 60, paused: false, at: start)
        #expect(clock.position(at: start.addingTimeInterval(1.5)) == 61.5)
        // The server's whole-second readings lag; a lower one doesn't pull the clock back…
        clock.observe(position: 61, paused: false, at: start.addingTimeInterval(1.5))
        #expect(clock.position(at: start.addingTimeInterval(2)) == 62)
        // …a higher one (a better estimate) moves it up.
        clock.observe(position: 62.8, paused: false, at: start.addingTimeInterval(2.5))
        #expect(abs(clock.position(at: start.addingTimeInterval(3)) - 63.3) < 0.0001)
    }

    @Test func liveClockFollowsSeeksAndPauses() {
        let start = Date(timeIntervalSince1970: 1_000)
        var clock = LiveClock()
        clock.observe(position: 600, paused: false, at: start)
        // A seek back well past the lag is taken as is.
        clock.observe(position: 300, paused: false, at: start.addingTimeInterval(2))
        #expect(clock.position(at: start.addingTimeInterval(3)) == 301)
        // A seek forward too.
        clock.observe(position: 900, paused: false, at: start.addingTimeInterval(4))
        #expect(clock.position(at: start.addingTimeInterval(4)) == 900)
        // Paused: it stands still at the reading.
        clock.observe(position: 905, paused: true, at: start.addingTimeInterval(9))
        #expect(clock.position(at: start.addingTimeInterval(30)) == 905)
        // Resumed: it advances again from the first reading.
        clock.observe(position: 905, paused: false, at: start.addingTimeInterval(30))
        #expect(clock.position(at: start.addingTimeInterval(32)) == 907)
    }

    @Test func trickplayCellsAndSheets() throws {
        let json = Data(#"{"Id":"E","Name":"Ep","Type":"Episode","Trickplay":{"src1":{"320":{"Width":320,"Height":180,"TileWidth":10,"TileHeight":10,"ThumbnailCount":250,"Interval":10000,"Bandwidth":1000},"480":{"Width":480,"Height":270,"TileWidth":10,"TileHeight":10,"ThumbnailCount":250,"Interval":10000,"Bandwidth":1000}}}}"#.utf8)
        let item = try JellyfinClient.decoder.decode(JellyfinItem.self, from: json)
        let info = try #require(item.trickplay(mediaSourceId: "src1"))
        #expect(info.width == 320)
        // 125 s → thumbnail 12: sheet 0, row 1, column 2.
        let cell = try #require(info.cell(at: 125))
        #expect(cell.sheet == 0 && cell.x == 640 && cell.y == 180)
        // 1_005 s → thumbnail 100: the second sheet's first cell.
        let later = try #require(info.cell(at: 1_005))
        #expect(later.sheet == 1 && later.x == 0 && later.y == 0)
        // Past the end: the last thumbnail.
        #expect(info.cell(at: 99_999)?.sheet == 2)
        let request = client(StubTransport { _ in (200, Data()) }).trickplaySheetRequest(itemId: "E", mediaSourceId: "src1", width: 320, sheet: 1)
        #expect(request.url!.path() == "/Videos/E/Trickplay/320/1.jpg")
        #expect(query(request)["mediaSourceId"] == "src1")
    }

    @Test func mediaSegmentsKeepKnownKinds() async throws {
        let data = try fixture("media-segments.json")
        let transport = StubTransport { _ in (200, data) }
        let segments = try await client(transport).mediaSegments(itemId: "E1")
        #expect(transport.requests.map { $0.url!.path() } == ["/MediaSegments/E1"])
        #expect(segments.map(\.kind) == [.intro, .outro])
        #expect(abs(segments[0].end - 89.99) < 0.001)
        #expect(abs(segments[1].start - 1410.01) < 0.001)
        #expect(JellyfinMediaSegment.at(45, in: segments)?.kind == .intro)
        #expect(JellyfinMediaSegment.at(90, in: segments) == nil)
        #expect(JellyfinMediaSegment.at(1500, in: segments)?.kind == .outro)
    }

    @Test func seasonsCarryTheirAniDBId() throws {
        let json = Data(#"{"Id":"S2","Name":"Season 2","Type":"Season","ProviderIds":{"AniDB":"12345","Custom":"shoko://series/6","Shoko Series":"6"}}"#.utf8)
        #expect(try JellyfinClient.decoder.decode(JellyfinItem.self, from: json).anidbId == 12345)
        #expect(try JellyfinClient.decoder.decode(JellyfinItem.self, from: Data(#"{"Id":"X","Name":"x","Type":"Season"}"#.utf8)).anidbId == nil)
    }

    @Test func sessionsReportTheServersPosition() throws {
        let session = try JellyfinClient.decoder.decode([JellyfinSession].self, from: try fixture("sessions.json"))[0]
        #expect(session.reportedPosition == 869.921341)
    }

    @Test func playstateCommandsPost() async throws {
        let transport = StubTransport { _ in (204, Data()) }
        try await client(transport).sendPlaystate(sessionId: "S1", .pause)
        try await client(transport).sendPlaystate(sessionId: "S1", .unpause)
        #expect(transport.requests.map(\.httpMethod) == ["POST", "POST"])
        #expect(transport.requests.map { $0.url!.path() } == ["/Sessions/S1/Playing/Pause", "/Sessions/S1/Playing/Unpause"])
    }

    @Test func downloadURLKeepsTheTokenOutOfTheURL() {
        let url = client(StubTransport { _ in (200, Data()) }).downloadURL(itemId: "E")
        #expect(url.path() == "/Items/E/Download")
        #expect(url.query() == nil)
    }

    @Test func ffmpegIndexSkipsExternalStreams() throws {
        let item = try JellyfinClient.decoder.decode(JellyfinItem.self, from: try fixture("item.json"))
        let streams = try #require(item.mediaSources?.first?.mediaStreams)
        let index = { (i: Int) in streams.first { $0.index == i }!.ffmpegIndex(in: streams) }
        #expect(index(4) == 0)   // video
        #expect(index(6) == 2)   // Japanese audio
        #expect(index(1) == nil) // external SRT
    }
}
