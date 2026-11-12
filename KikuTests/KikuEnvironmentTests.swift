import AppCommon
import AudiobookshelfKit
import Core
import Foundation
@testable import Kiku
import Testing

@MainActor @Suite struct KikuEnvironmentTests {
    func environment() -> KikuEnvironment {
        let temp = URL.temporaryDirectory.appending(path: "KikuTests-\(UUID().uuidString)")
        return KikuEnvironment(database: try! AppDatabase.inMemory(), secrets: InMemorySecretStore(),
                               mediaDirectory: temp.appending(path: "Media"), dictionaryDirectory: temp.appending(path: "Dictionaries"),
                               downloadsDirectory: temp.appending(path: "Downloads"), backgroundDownloads: false, sendsProgress: false, sendsCards: false)
    }

    @Test func markNeedsSomethingPlaying() {
        #expect(environment().mark(.shortcut) == nil)
    }

    @Test func noClientsUntilSetUp() throws {
        let environment = environment()
        #expect(environment.audiobookshelfClient() == nil)
        #expect(environment.kakuClient() == nil)
        try environment.common.accounts.save(ServerAccount(kind: .kaku, baseURL: URL(string: "https://kaku.example")!))
        #expect(environment.kakuClient() == nil)
        try environment.common.secrets.setSecret("t", for: .kakuAPIToken)
        #expect(environment.kakuClient()?.baseURL.host() == "kaku.example")
        try environment.common.accounts.save(ServerAccount(kind: .audiobookshelf, baseURL: URL(string: "https://abs.example")!))
        #expect(environment.audiobookshelfClient()?.baseURL.host() == "abs.example")
    }

    /// Offline (nothing listens on the port): the saved shelves stay, and a show without a
    /// saved copy lists its downloads.
    @Test func offlineKeepsTheSavedLibraryAndDownloads() async throws {
        let environment = environment()
        let server = URL(string: "http://127.0.0.1:9")!
        try environment.common.accounts.save(ServerAccount(kind: .audiobookshelf, baseURL: server))
        try environment.common.secrets.setSecret("t", for: .audiobookshelfToken)
        let show = try JSONDecoder().decode(AudiobookshelfItem.self, from: Data("""
            {"id": "show", "libraryId": "lib", "mediaType": "podcast", "media": {"metadata": {"title": "ことばの寄り道ラジオ"}}}
            """.utf8))
        let saved = PodcastLibrary.Saved(server: server, shows: [show], newEpisodes: [], continueListening: [],
                                         progress: [:], transcriptStatus: [:], newCounts: ["show": 2])
        try AudiobookshelfCacheStore(database: environment.common.database).save(JSONEncoder().encode(saved), for: "home")

        let meta = DownloadedAudio(itemId: "other", episodeId: "ep", title: "#1", showTitle: "Other show", duration: 60,
                                   publishedAt: 1, ino: "1", file: "other-ep.mp3")
        let store = DownloadStore(database: environment.common.database)
        let record = try store.enqueue(DownloadRecord(kind: .audiobookshelfEpisode, itemKey: "other/ep", seriesKey: "other",
                                                      seriesTitle: "Other show", title: "#1", extra: JSONEncoder().encode(meta), createdAt: .now))
        try store.finish(record.id!, file: nil, bytes: 1)
        let watcher = Task { await environment.downloader.start() }
        defer { watcher.cancel() }
        for _ in 0..<100 where environment.downloadedEntries.isEmpty { try await Task.sleep(for: .milliseconds(20)) }

        await environment.library.refresh()
        #expect(environment.library.isOffline)
        #expect(environment.library.shows.map(\.id) == ["show"])
        #expect(environment.library.newCounts["show"] == 2)
        #expect(environment.downloadedEntries.map(\.id) == ["other/ep"])

        await environment.library.loadShow("other")
        #expect(environment.library.showEpisodes["other"]?.map(\.id) == ["ep"])
        #expect(environment.library.showTitle("other") == "Other show")
    }

    /// A book is one long "episode" keyed by its item, with chapters for the player and cards.
    @Test func aBookEntry() throws {
        let json = ##"{"id":"book","libraryId":"books","mediaType":"book","media":{"metadata":{"title":"本","authorName":"著者"},"duration":60,"chapters":[{"id":0,"start":0,"end":30,"title":"一"},{"id":1,"start":30,"end":60,"title":"二"}],"tracks":[{"index":1,"ino":"9","startOffset":0,"duration":60}]}}"##
        let item = try JSONDecoder().decode(AudiobookshelfItem.self, from: Data(json.utf8))
        let entry = try #require(environment().library.entry(book: item))
        #expect(entry.id == "book" && entry.isBook && entry.showTitle == "著者" && entry.collectionTitle == "本")
        #expect(entry.chapter(at: 29.9)?.title == "一" && entry.chapter(at: 31)?.title == "二")
        #expect(EpisodeAudio.miscInfo(entry, at: 45) == CardSource.miscInfo(show: "本", episode: "二", time: 45))
        #expect(entry.fileCount == 1)
    }
}
