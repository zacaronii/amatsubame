import Foundation
import KavitaKit
import Readers
import Testing
@testable import Yomu

/// A fetch for the list's next is used only if what it was started from is still open.
@MainActor @Suite struct ReaderSwapTests {
    func session(_ chapterId: Int, list: Int64?) -> ReaderSession {
        let series = KavitaSeries(id: 1, name: "Series", libraryId: 1, format: 1, pages: 10, pagesRead: 0)
        var session = ReaderSession(chapter: ReaderChapter(chapterId: chapterId, volumeId: chapterId, seriesId: 1, libraryId: 1, pages: 10,
                                                           title: "Vol. \(chapterId)", seriesTitle: "Series"),
                                    series: series, contents: KavitaSeriesContents(volumes: []))
        session.readingListId = list
        return session
    }

    @Test func aFetchAppliesOnlyToTheChapterItStartedFrom() {
        let from = ReaderContainer.Reading(chapterId: 1, listId: 7)
        #expect(from.isStill(session(1, list: 7)))
        #expect(!from.isStill(session(2, list: 7)), "Next in series opened meanwhile")
        #expect(!from.isStill(session(1, list: nil)), "a link opened the same volume outside the list")
    }
}
