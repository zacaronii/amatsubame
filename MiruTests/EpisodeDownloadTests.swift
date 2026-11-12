import AppCommon
import Core
import Foundation
@testable import Miru
import JellyfinKit
import Testing

@MainActor @Suite struct EpisodeDownloadTests {
    let client = JellyfinClient(baseURL: URL(string: "https://jellyfin.example.ts.net")!,
                                identity: JellyfinClientIdentity(device: "iPhone", deviceId: "d", version: "1"),
                                accessToken: "tok", userId: "U")

    /// An episode as Jellyfin's item endpoint returns it (trimmed).
    func episode() throws -> JellyfinItem {
        let json = """
        {"Id":"E1","Name":"Pilot","Type":"Episode","SeriesId":"S","SeriesName":"Show","SeasonId":"SS","IndexNumber":3,
         "ParentIndexNumber":1,"RunTimeTicks":14210450000,
         "MediaSources":[{"Id":"M1","Container":"mkv,webm","Size":1818599438,"MediaStreams":[
           {"Index":0,"Type":"Subtitle","Language":"eng","Codec":"subrip","IsExternal":true,"IsTextSubtitleStream":true},
           {"Index":1,"Type":"Video","Codec":"h264","IsExternal":false},
           {"Index":2,"Type":"Audio","Language":"eng","Codec":"aac","IsExternal":false},
           {"Index":3,"Type":"Audio","Language":"jpn","Codec":"aac","IsExternal":false}]}]}
        """
        return try JellyfinClient.decoder.decode(JellyfinItem.self, from: Data(json.utf8))
    }

    @Test func requestUsesHeaderAuthAndTheWiFiRule() {
        let wifiOnly = EpisodeDownloader.request(client: client, itemId: "E1", allowsCellular: false)
        #expect(wifiOnly.url?.path() == "/Items/E1/Download")
        #expect(wifiOnly.url?.absoluteString.contains("tok") == false)
        #expect(wifiOnly.value(forHTTPHeaderField: "Authorization")?.hasSuffix(#"Token="tok""#) == true)
        #expect(!wifiOnly.allowsExpensiveNetworkAccess && !wifiOnly.allowsConstrainedNetworkAccess)
        let anyNetwork = EpisodeDownloader.request(client: client, itemId: "E1", allowsCellular: true)
        #expect(anyNetwork.allowsExpensiveNetworkAccess && anyNetwork.allowsConstrainedNetworkAccess)
    }

    @Test func savedDetailsPlayOffline() throws {
        let item = try episode()
        let meta = DownloadedEpisode(item: item, source: try #require(item.mediaSources?.first))
        #expect(meta.file == "E1.mkv")
        // Japanese audio is Jellyfin stream 3, after one external subtitle: FFmpeg's 2.
        #expect(meta.audioIndex == 2)
        let restored = meta.item
        #expect(restored.episodeLabel == "S1E3" && restored.seriesName == "Show")
        #expect(restored.duration == 1421.045)
    }

    @Test func finishedDownloadIsPlayedFromTheDevice() async throws {
        let environment = PlayerEnvironment.preview()
        let downloader = environment.downloader
        let item = try episode()
        let meta = DownloadedEpisode(item: item, source: try #require(item.mediaSources?.first))
        let record = try environment.common.downloads.enqueue(DownloadRecord(
            kind: .jellyfinItem, itemKey: "E1", seriesKey: "S", seriesTitle: "Show", title: "S1E3 · Pilot",
            extra: try JSONEncoder().encode(meta), createdAt: Date()))
        #expect(downloader.localFile(itemId: "E1") == nil)

        try FileManager.default.createDirectory(at: downloader.directory, withIntermediateDirectories: true)
        try Data("video".utf8).write(to: downloader.directory.appending(path: meta.file))
        try environment.common.downloads.finish(try #require(record.id), file: meta.file, bytes: 5)
        #expect(downloader.localFile(itemId: "E1")?.lastPathComponent == "E1.mkv")
        #expect(downloader.metadata(itemId: "E1")?.mediaSourceId == "M1")

        let done = try #require(try environment.common.downloads.download(kind: .jellyfinItem, itemKey: "E1"))
        await downloader.delete(done)
        #expect(!FileManager.default.fileExists(atPath: downloader.directory.appending(path: meta.file).path()))
        #expect(try environment.common.downloads.download(kind: .jellyfinItem, itemKey: "E1") == nil)
    }
}
