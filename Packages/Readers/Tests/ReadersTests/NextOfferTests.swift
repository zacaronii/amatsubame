import Foundation
@testable import Readers
import Testing

/// The end of a chapter while reading in a reading list.
@Suite struct NextOfferTests {
    func chapter(_ id: Int, series: Int = 1) -> ReaderChapter {
        ReaderChapter(chapterId: id, volumeId: id, seriesId: series, libraryId: 1, pages: 10, title: "Vol. \(id)", seriesTitle: "Series")
    }

    @Test func theListsNextFirstAndTheSeriesNextSecond() {
        let offer = NextOffer.reading(in: "Later", .next(chapter(9, series: 2), label: "Other · Vol. 9", detail: "skipped 1 PDF"), seriesNext: chapter(2))
        #expect(offer.primary?.label == "Next in \u{201C}Later\u{201D}: Other · Vol. 9")
        #expect(offer.primary?.detail == "skipped 1 PDF")
        #expect(offer.secondary?.chapter.chapterId == 2)
        #expect(offer.secondary?.label == "Next in series: Vol. 2")
        #expect(offer.heading == nil)
    }

    @Test func oneButtonWhenBothAreTheSameChapter() {
        let offer = NextOffer.reading(in: "Later", .next(chapter(2), label: "Series · Vol. 2", detail: nil), seriesNext: chapter(2))
        #expect(offer.primary?.chapter.chapterId == 2)
        #expect(offer.secondary == nil)
    }

    @Test func theEndOfTheListOffersTheSeriesNext() {
        let offer = NextOffer.reading(in: "Later", .end(detail: "skipped 2 in hidden libraries"), seriesNext: chapter(2))
        #expect(offer.heading == "End of \u{201C}Later\u{201D}")
        #expect(offer.headingDetail == "skipped 2 in hidden libraries")
        #expect(offer.primary?.label == "Next in series: Vol. 2")
        #expect(offer.secondary == nil)
        #expect(NextOffer.reading(in: "Later", .end(detail: nil), seriesNext: nil).primary == nil)
    }

    @Test func notInTheListIsTheSeriesNextLabelledSo() {
        let offer = NextOffer.reading(in: "Later", .notInList, seriesNext: chapter(2))
        #expect(offer.heading == nil)
        #expect(offer.primary?.label == "Next in series: Vol. 2")
        #expect(NextOffer.reading(in: "Later", .notInList, seriesNext: nil) == NextOffer())
    }
}
