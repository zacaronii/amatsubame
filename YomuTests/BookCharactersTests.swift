import Core
import Foundation
import KavitaKit
import Testing
@testable import Yomu

/// A book's progress in Yomu's own counts, never Kavita's percentage.
@MainActor @Suite struct BookCharactersTests {
    func chapter(_ id: Int, pages: Int = 4, read: Int = 0, words: Int? = nil, kavitaAt: Date? = nil) -> KavitaChapter {
        var chapter = KavitaChapter(id: id, volumeId: id, number: "-100000", sortOrder: Double(id), pages: pages, pagesRead: read, wordCount: words)
        chapter.lastReadingProgressUtc = kavitaAt
        return chapter
    }

    func length(_ id: Int, _ sections: [Int]) -> BookLength {
        BookLength(chapterId: id, seriesId: 1, sections: sections, kavitaWordCount: nil, kavitaPages: sections.count, countedAt: .now)
    }

    func local(_ id: Int, page: Int, characters: Int?) -> LocalReadingProgress {
        LocalReadingProgress(chapterId: id, seriesId: 1, volumeId: id, libraryId: 1, page: page, pages: 4, updatedAt: .now,
                             scrollId: nil, characters: characters)
    }

    @Test func countedVolumeUsesThisDevicesPlaceOrKavitasSection() {
        let counted = length(1, [0, 100, 50, 200])
        // Kavita says section 2: everything before it.
        #expect(BookCharacters.progress(chapter(1, read: 2), length: counted, local: nil) == BookProgress(read: 100, total: 350))
        // This device is there (or further, not sent yet): its own count.
        #expect(BookCharacters.progress(chapter(1, read: 2), length: counted, local: local(1, page: 3, characters: 220))?.read == 220)
        // Kavita further but older (this device went back, or its progress is held): this device's.
        #expect(BookCharacters.progress(chapter(1, read: 3, kavitaAt: .distantPast), length: counted,
                                        local: local(1, page: 2, characters: 120))?.read == 120)
        // Another device read on since: Kavita's section.
        #expect(BookCharacters.progress(chapter(1, read: 3, kavitaAt: .now.addingTimeInterval(60)), length: counted,
                                        local: local(1, page: 2, characters: 120))?.read == 150)
        #expect(BookCharacters.progress(chapter(1, read: 4), length: counted, local: nil) == BookProgress(read: 350, total: 350))
    }

    @Test func uncountedVolumeIsAnEstimateFromKavitasWordCount() {
        let estimate = BookCharacters.progress(chapter(1, read: 0, words: 1000), length: nil, local: nil)
        #expect(estimate == BookProgress(read: 0, total: 5000, isEstimate: true))
        #expect(estimate?.percent == "~0%")
        #expect(BookCharacters.progress(chapter(1), length: nil, local: nil) == nil)
    }

    @Test func seriesAddsVolumesAndKeepsEstimatesMarked() {
        let chapters = [chapter(1, read: 4), chapter(2, read: 0, words: 100), chapter(3, read: 2)]
        let lengths = [1: length(1, [100, 100, 100, 100]), 3: length(3, [50, 50, 50, 50])]
        let series = BookCharacters.series(chapters, lengths: lengths, local: [:])
        #expect(series == BookProgress(read: 400 + 0 + 100, total: 400 + 500 + 200, isEstimate: true))
        #expect(BookCharacters.series([chapter(1, read: 4), chapter(4)], lengths: lengths, local: [:]) == nil)
    }
}
