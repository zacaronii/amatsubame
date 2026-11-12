@testable import Core
import Foundation
import Testing

@Suite struct AudioTranscriptStoreTests {
    let day = Date(timeIntervalSince1970: 1_793_400_000)

    func info(_ episode: String, played: Date?) -> AudioTranscriptInfo {
        AudioTranscriptInfo(itemId: "show", episodeId: episode, showTitle: "ことばの散歩ラジオ", episodeTitle: "#\(episode)",
                            fingerprint: "1:2:3", duration: 1800, savedAt: day, lastPlayedAt: played)
    }

    func sentences(_ episode: String, _ texts: [String]) -> [AudioSentence] {
        texts.enumerated().map { index, text in
            AudioSentence(key: "show/\(episode)", position: index, start: Double(index * 4), end: Double(index * 4 + 3), text: text,
                          words: [.init(text: text, start: Double(index * 4), end: Double(index * 4 + 3))])
        }
    }

    func store() throws -> AudioTranscriptStore {
        let store = AudioTranscriptStore(database: try AppDatabase.inMemory())
        try store.save(info("1", played: day), sentences: sentences("1", ["当時の意思決定の仕組み", "そうなんですよ。", "老中たちが合議で決める"]))
        try store.save(info("2", played: day.addingTimeInterval(60)), sentences: sentences("2", ["チームの意思決定", "はい。"]))
        // Downloaded, never played: not searched.
        try store.save(info("3", played: nil), sentences: sentences("3", ["意思決定の話"]))
        return store
    }

    @Test func savesAndReplacesKeepingThePlayedTime() throws {
        let store = try store()
        let saved = try store.sentences(key: "show/1")
        #expect(saved.map(\.text) == ["当時の意思決定の仕組み", "そうなんですよ。", "老中たちが合議で決める"])
        #expect(saved[1].start == 4 && saved[1].words.first?.end == 7)
        try store.save(info("1", played: nil), sentences: sentences("1", ["新しい"]))
        #expect(try store.sentences(key: "show/1").map(\.text) == ["新しい"])
        #expect(try store.transcript(key: "show/1")?.lastPlayedAt == day)
        #expect(try store.savedKeys() == ["show/1", "show/2", "show/3"])
    }

    @Test func searchesPlayedEpisodesNewestFirst() throws {
        let store = try store()
        let groups = try store.search("意思決定")
        #expect(groups.map(\.transcript.episodeId) == ["2", "1"])
        #expect(groups[1].sentences.map(\.position) == [0])
        // Short queries scan with LIKE.
        #expect(try store.search("合議").map(\.transcript.episodeId) == ["1"])
        #expect(try store.search("  ").isEmpty)
        try store.touch(key: "show/3", at: day.addingTimeInterval(120))
        #expect(try store.search("意思決定").first?.transcript.episodeId == "3")
    }

    @Test func deletes() throws {
        let store = try store()
        try store.delete(key: "show/1")
        #expect(try store.sentences(key: "show/1").isEmpty)
        #expect(try store.search("合議").isEmpty)
        #expect(try store.approximateBytes() > 0)
    }

    @Test func cacheKeepsTheLastAnswerPerKey() throws {
        let cache = AudiobookshelfCacheStore(database: try AppDatabase.inMemory())
        #expect(try cache.data(for: "home") == nil)
        try cache.save(Data("1".utf8), for: "home")
        try cache.save(Data("2".utf8), for: "home")
        try cache.save(Data("show".utf8), for: "show:a")
        #expect(try cache.data(for: "home") == Data("2".utf8))
        try cache.clear()
        #expect(try cache.data(for: "show:a") == nil)
    }

    @Test func listenSettingsKeepHiddenLibraries() throws {
        let database = try AppDatabase.inMemory()
        #expect(ListenSettings.load(database).hiddenLibraries.isEmpty)
        var settings = ListenSettings.load(database)
        settings.hiddenLibraries = ["english"]
        try settings.save(database)
        #expect(ListenSettings.load(database).hiddenLibraries == ["english"])
    }

    /// The transcript is on until switched off, and stays off for every episode.
    @Test func transcriptChoiceIsKept() throws {
        let database = try AppDatabase.inMemory()
        #expect(ListenSettings.load(database).showsTranscript)
        var settings = ListenSettings.load(database)
        settings.showsTranscript = false
        try settings.save(database)
        #expect(!ListenSettings.load(database).showsTranscript)
    }
}
