import Core
import Foundation
import Testing

@Suite struct AudioMarkStoreTests {
    final class Clock: @unchecked Sendable {
        var date = Date(timeIntervalSince1970: 1_793_400_000)
    }

    func mark(_ time: Double, at date: Date) -> AudioMark {
        AudioMark(itemId: "show", episodeId: "ep", showTitle: "まいにち雑談ラジオ", episodeTitle: "#312", time: time,
                  createdAt: date, source: .shortcut)
    }

    @Test func newestFirstAndClear() throws {
        let clock = Clock()
        let store = AudioMarkStore(database: try AppDatabase.inMemory(), now: { clock.date })
        let first = try store.add(mark(801, at: clock.date))
        try store.add(mark(807, at: clock.date.addingTimeInterval(5)))
        #expect(try store.marks().map(\.time) == [807, 801])
        #expect(try store.marks().first?.key == "show/ep")
        let book = AudioMark(itemId: "book", episodeId: "", showTitle: "著者", episodeTitle: "本", time: 3, createdAt: clock.date, source: .player)
        #expect(book.key == "book", "a book has no episode")
        try store.remove(first.id!)
        #expect(try store.marks().map(\.time) == [807])
    }

    @Test func minedMarksStayADayAndUndoBringsThemBack() throws {
        let clock = Clock()
        let store = AudioMarkStore(database: try AppDatabase.inMemory(), now: { clock.date })
        let mined = try store.add(mark(801, at: clock.date))
        let undone = try store.add(mark(900, at: clock.date))
        try store.setMined(mined.id!, word: "合議", jobId: 7)
        try store.setMined(undone.id!, word: "仕組み", jobId: 8)
        try store.setUnmined(jobId: 8)
        let marks = try store.marks()
        #expect(marks.first { $0.id == mined.id }?.minedWord == "合議")
        #expect(marks.first { $0.id == undone.id }?.isMined == false)

        clock.date = clock.date.addingTimeInterval(AudioMarkStore.minedKeptFor + 60)
        #expect(try store.marks().map(\.id) == [undone.id])
        try store.pruneMined()
        #expect(try store.marks().count == 1)
    }

    @Test func readAlongPairsAndTheirAlignment() throws {
        let store = ReadAlongStore(database: try AppDatabase.inMemory())
        #expect(try store.pair(chapterId: 7) == nil)
        try store.pair(ReadAlongPair(chapterId: 7, itemId: "book", bookTitle: "森の灯り", createdAt: Date(timeIntervalSince1970: 0)))
        try store.saveAlignment(chapterId: 7, cues: Data("[]".utf8), version: 1, fingerprint: "f", matched: 9, total: 10, at: Date(timeIntervalSince1970: 5))
        let pair = try #require(try store.pair(chapterId: 7))
        #expect(pair.itemId == "book" && pair.cues == Data("[]".utf8) && pair.matchedSentences == 9 && pair.alignmentVersion == 1)
        // Pairing again (another book) starts without an alignment.
        try store.pair(ReadAlongPair(chapterId: 7, itemId: "other", bookTitle: "別", createdAt: .now))
        #expect(try store.pair(chapterId: 7)?.cues == nil)
        try store.unpair(chapterId: 7)
        #expect(try store.pair(chapterId: 7) == nil)
    }
}
