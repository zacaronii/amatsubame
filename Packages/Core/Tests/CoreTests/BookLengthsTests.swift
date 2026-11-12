import Core
import Foundation
import Testing

@Suite struct BookLengthsTests {
    @Test func savesAndReadsBySeries() throws {
        let store = BookLengths(database: try AppDatabase.inMemory())
        try store.save(BookLength(chapterId: 1, seriesId: 10, sections: [0, 100, 50], kavitaWordCount: 30, kavitaPages: 3, countedAt: .now))
        try store.save(BookLength(chapterId: 2, seriesId: 10, sections: [200], kavitaWordCount: 40, kavitaPages: 1, countedAt: .now))
        try store.save(BookLength(chapterId: 3, seriesId: 11, sections: [5], kavitaWordCount: 1, kavitaPages: 1, countedAt: .now))
        let lengths = try store.lengths(seriesId: 10)
        #expect(lengths.keys.sorted() == [1, 2])
        #expect(lengths[1]?.total == 150 && lengths[1]?.start(of: 2) == 100)
        #expect(try store.all().count == 3)
    }

    /// Counted from the opened book (no word count known there): Kavita's word count from the
    /// counter is kept while the sections are the same.
    @Test func keepsKavitasWordCountForTheSameText() throws {
        let store = BookLengths(database: try AppDatabase.inMemory())
        try store.save(BookLength(chapterId: 1, seriesId: 10, sections: [7, 1, 7], kavitaWordCount: 16802, kavitaPages: 3, countedAt: .now))
        try store.save(BookLength(chapterId: 1, seriesId: 10, sections: [7, 1, 7], kavitaWordCount: nil, kavitaPages: 3, countedAt: .now))
        #expect(try store.length(chapterId: 1)?.kavitaWordCount == 16802)
    }

    @Test func staleWhenKavitasFiguresChange() {
        let length = BookLength(chapterId: 1, seriesId: 10, sections: [7, 1, 7], kavitaWordCount: 100, kavitaPages: 3, countedAt: .now)
        #expect(!length.isStale(pages: 3, wordCount: 100))
        #expect(!length.isStale(pages: 3, wordCount: nil))
        #expect(length.isStale(pages: 4, wordCount: 100))
        #expect(length.isStale(pages: 3, wordCount: 120))
    }
}
