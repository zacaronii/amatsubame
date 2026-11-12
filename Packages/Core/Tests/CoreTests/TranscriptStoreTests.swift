@testable import Core
import Foundation
import GRDB
import Testing

@Suite struct TranscriptStoreTests {
    let day = Date(timeIntervalSince1970: 1_793_400_000)

    func info(_ id: String, played: Date?) -> TranscriptInfo {
        TranscriptInfo(itemId: id, seriesId: "S", seriesName: "Star Captain", title: "Ep \(id)", season: 1, episode: 1,
                       mediaSourceId: "M\(id)", streamIndex: 1, runtime: 1420, lastPlayedAt: played, savedAt: day)
    }

    func store() throws -> TranscriptStore {
        let store = TranscriptStore(database: try AppDatabase.inMemory())
        try store.save(info("A", played: day), lines: [
            (1, 2, "その旅人の名前は"), (3, 4, "隊長の声が聞こえます"), (5, 6, "本当の気持ちを知りたいのです"),
        ])
        try store.save(info("B", played: day.addingTimeInterval(60)), lines: [(1, 2, "隊長！"), (3, 4, "100%の確率")])
        return store
    }

    @Test func savesAndReplaces() throws {
        let store = try store()
        #expect(try store.lines(itemId: "A").map(\.text) == ["その旅人の名前は", "隊長の声が聞こえます", "本当の気持ちを知りたいのです"])
        #expect(try store.lines(itemId: "A")[1].start == 3)
        try store.save(info("A", played: day), lines: [(9, 10, "新しい")])
        #expect(try store.lines(itemId: "A").map(\.text) == ["新しい"])
        #expect(try store.savedItemIds() == ["A", "B"])
        #expect(try store.recent().map(\.itemId) == ["B", "A"])
    }

    @Test func copiesOfALineMerge() {
        let lines: [(start: Double, end: Double, text: String)] = [
            (67.0, 69, "夢の中"), (67.1, 69, "夢の中"), (68, 70, "別"), (69.3, 71, "夢の中"), (80, 82, "夢の中"),
        ]
        let merged = TranscriptLines.mergingCopies(lines)
        #expect(merged.map(\.text) == ["夢の中", "別", "夢の中"])
        #expect(merged[0].start == 67 && merged[0].end == 71)
    }

    /// Karaoke build-ups: each step starts with the last and follows straight on.
    @Test func buildUpsMergeIntoTheFinishedLine() {
        let lines: [(start: Double, end: Double, text: String)] = [
            (22.0, 22.4, "夢"), (22.4, 24, "夢を見たから"), (30, 31, "夢"), (40, 41, "夢は"), (41.1, 43, "夢は空の向こう"),
        ]
        let merged = TranscriptLines.mergingBuildUps(lines)
        #expect(merged.map(\.text) == ["夢を見たから", "夢", "夢は空の向こう"])
        #expect(merged[0].start == 22 && merged[0].end == 24)
        #expect(merged[2].start == 40, "the finished line starts where the build-up did")
        // A line that merely starts the same way later on stays.
        #expect(TranscriptLines.mergingBuildUps([(1, 2, "そう"), (5, 6, "そうだね")]).count == 2)
    }

    @Test func savedCopiesAreMergedOnUpgrade() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v13_auto_downloads")
        try queue.write { db in
            try info("A", played: day).insert(db)
            for (cue, start) in [1.0, 1.1, 1.2, 5].enumerated() {
                try db.execute(sql: #"INSERT INTO transcriptLine (text, itemId, cue, start, "end") VALUES (?, 'A', ?, ?, ?)"#,
                               arguments: [start == 5 ? "次" : "歌", cue, start, start + 1])
            }
        }
        let store = TranscriptStore(database: try AppDatabase(queue))
        #expect(try store.lines(itemId: "A").map(\.text) == ["歌", "次"])
        #expect(try store.lines(itemId: "A").map(\.cue) == [0, 1])
        #expect(try store.lines(itemId: "A")[0].end == 2.2)
    }

    @Test func trigramSearchFindsSubstrings() throws {
        let store = try store()
        let groups = try store.search("知りたい")
        #expect(groups.map(\.id) == ["A"])
        #expect(groups[0].lines.map(\.cue) == [2])
    }

    @Test func shortQueriesScanAndGroupNewestFirst() throws {
        let store = try store()
        let groups = try store.search("隊長")
        #expect(groups.map(\.id) == ["B", "A"])
        #expect(groups[1].lines.map(\.text) == ["隊長の声が聞こえます"])
        // LIKE wildcards in the query are literal.
        #expect(try store.search("%").map(\.id) == ["B"])
        #expect(try store.search("  ").isEmpty)
    }

    @Test func touchReordersAndClearEmpties() throws {
        let store = try store()
        try store.touch(itemId: "A", at: day.addingTimeInterval(120))
        #expect(try store.search("隊長").map(\.id) == ["A", "B"])
        #expect(try store.approximateBytes() > 0)
        try store.clear()
        #expect(try store.savedItemIds().isEmpty)
        #expect(try store.search("隊長").isEmpty)
    }

    @Test func localSubtitlesKeepOffsetAndUpload() throws {
        let store = LocalSubtitleStore(database: try AppDatabase.inMemory())
        let saved = Date(timeIntervalSince1970: 1_793_400_000)
        try store.save(LocalSubtitle(itemId: "E", source: "jimaku", fileName: "a.srt", format: "srt", data: Data("x".utf8), savedAt: saved))
        try store.setOffset(-1.5, itemId: "E")
        try store.markUploaded(itemId: "E", at: saved.addingTimeInterval(60))
        let subtitle = try #require(try store.subtitle(itemId: "E"))
        #expect(subtitle.offset == -1.5 && subtitle.uploadedAt == saved.addingTimeInterval(60))
        // A new pick replaces it; the old file is still on the server.
        try store.save(LocalSubtitle(itemId: "E", source: "jimaku", fileName: "b.ass", format: "ass", data: Data("y".utf8), savedAt: saved))
        let replaced = try #require(try store.subtitle(itemId: "E"))
        #expect(replaced.fileName == "b.ass" && replaced.offset == 0 && replaced.uploadedAt == saved.addingTimeInterval(60))
        #expect(replaced.serverState == .olderSaved)
        #expect(try store.subtitle(itemId: "F") == nil)
    }

    @Test func savingToTheServerFollowsEdits() throws {
        let store = LocalSubtitleStore(database: try AppDatabase.inMemory())
        let start = Date(timeIntervalSince1970: 1_793_400_000)
        try store.save(LocalSubtitle(itemId: "E", source: "jimaku", fileName: "a.srt", format: "srt", data: Data("x".utf8), savedAt: start))
        #expect(try store.subtitle(itemId: "E")?.serverState == .notSaved)
        try store.markQueued(itemId: "E", at: start.addingTimeInterval(10))
        #expect(try store.subtitle(itemId: "E")?.serverState == .queued)
        try store.markUploaded(itemId: "E", at: start.addingTimeInterval(20))
        #expect(try store.subtitle(itemId: "E")?.serverState == .saved)
        try store.setOffset(0.5, itemId: "E", at: start.addingTimeInterval(30))
        #expect(try store.subtitle(itemId: "E")?.serverState == .olderSaved)
    }

    @Test func syncKeepsTheDownloadForReset() throws {
        let store = LocalSubtitleStore(database: try AppDatabase.inMemory())
        let start = Date(timeIntervalSince1970: 1_793_400_000)
        try store.save(LocalSubtitle(itemId: "E", source: "jimaku", fileName: "a.srt", format: "srt", data: Data("orig".utf8), savedAt: start))
        try store.setOffset(2, itemId: "E")
        try store.saveSynced(Data("sync1".utf8), itemId: "E")
        try store.saveSynced(Data("sync2".utf8), itemId: "E")
        var subtitle = try #require(try store.subtitle(itemId: "E"))
        #expect(subtitle.data == Data("sync2".utf8) && subtitle.originalData == Data("orig".utf8) && subtitle.offset == 0)
        try store.restoreOriginal(itemId: "E")
        subtitle = try #require(try store.subtitle(itemId: "E"))
        #expect(subtitle.data == Data("orig".utf8) && subtitle.originalData == nil && subtitle.offset == 0)
    }

    @Test func serverCopiesKeepTheirTrackAndFile() throws {
        let store = LocalSubtitleStore(database: try AppDatabase.inMemory())
        try store.save(LocalSubtitle(itemId: "E", source: "jellyfin", fileName: "Japanese", format: "ass", data: Data("x".utf8),
                                     offset: 1.5, savedAt: day, serverIndex: 3, serverPath: "/m/ep.ja.ass"))
        let saved = try #require(try store.subtitle(itemId: "E"))
        #expect(saved.isServerCopy && saved.serverIndex == 3 && saved.serverPath == "/m/ep.ja.ass" && saved.offset == 1.5)
    }
}
