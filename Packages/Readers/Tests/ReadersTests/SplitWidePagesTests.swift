import CoreGraphics
import OCR
@testable import Readers
import Testing

/// Split Wide Pages: a two-page scan shown one half at a time in a portrait reader.
@Suite struct SplitWidePagesTests {
    func slots(_ count: Int, wide: Set<Int>, spreads: Bool = false, splits: Bool) -> [ReaderSlot] {
        SpreadLayout.readerSlots(pageCount: count, widePages: wide, spreads: spreads, coverAlone: true, splitsWide: splits)
    }

    @Test func aWidePageIsTwoHalvesInPortrait() {
        let portrait = slots(4, wide: [2], splits: true)
        #expect(portrait.map(\.pages) == [[0], [1], [2], [2], [3]])
        #expect(portrait.map(\.half) == [nil, nil, .first, .second, nil])
    }

    @Test func theViewportDecidesNotTheSpreadsSetting() {
        // Landscape (no split) with spreads off: the wide page stays whole.
        #expect(slots(4, wide: [2], spreads: false, splits: false).map(\.half) == [nil, nil, nil, nil])
        // Portrait with spreads on: the wide page stands alone, and is split.
        let spread = slots(6, wide: [3], spreads: true, splits: true)
        #expect(spread.map(\.pages) == [[0], [1, 2], [3], [3], [4, 5]])
        #expect(spread.filter { $0.half != nil }.count == 2)
    }

    @Test func offIsTodaysLayoutExactly() {
        for spreads in [false, true] {
            let off = slots(8, wide: [4], spreads: spreads, splits: false).map(\.pages)
            #expect(off == SpreadLayout.slots(pageCount: 8, widePages: [4], spreads: spreads, coverAlone: true))
        }
    }

    @Test func theFirstHalfIsTheRightOneInARightToLeftBook() {
        let first = ReaderSlot(pages: [2], half: .first), second = ReaderSlot(pages: [2], half: .second)
        #expect(first.visibleRange(rightToLeft: true) == 0.5...1)
        #expect(second.visibleRange(rightToLeft: true) == 0...0.5)
        #expect(first.visibleRange(rightToLeft: false) == 0...0.5)
        #expect(second.visibleRange(rightToLeft: false) == 0.5...1)
        #expect(ReaderSlot(pages: [1]).visibleRange(rightToLeft: true) == 0...1)
    }

    @Test func goingBackLandsOnTheFarHalfAndJumpsLandOnTheFirst() {
        let all = slots(4, wide: [2, 3], splits: true)   // 0, 1, 2a, 2b, 3a, 3b
        let next = SpreadLayout.slotIndex(containing: 3, in: all)
        #expect(all[next].half == .first, "opening, the slider and Continue: the first half")
        #expect(all[next - 1] == ReaderSlot(pages: [2], half: .second), "one back from page 3: page 2's second half")
        // The end page is one past the last slot: back from it is the last page's second half.
        #expect(all[all.count - 1] == ReaderSlot(pages: [3], half: .second))
    }

    @Test func aResizeKeepsTheHalfWhileStillSplit() {
        let portrait = slots(4, wide: [2], splits: true)
        let second = ReaderSlot(pages: [2], half: .second)
        #expect(SpreadLayout.slotIndex(keeping: second, page: 2, in: portrait) == 3, "still split: the same half")
        let landscape = slots(4, wide: [2], splits: false)
        let whole = landscape[SpreadLayout.slotIndex(keeping: second, page: 2, in: landscape)]
        #expect(whole == ReaderSlot(pages: [2]), "landscape: the whole page")
        #expect(SpreadLayout.slotIndex(keeping: whole, page: 2, in: portrait) == 2, "and back: its first half")
    }

    @Test func aHalfShowsItsBlocksMappedAndOnlyThose() {
        let place = OCRTextLayer.Placement(layer: CGSize(width: 100, height: 300), visible: 0.5...1)
        #expect(place.page == CGSize(width: 200, height: 300))
        let right = NormalizedRect(x: 0.6, y: 0.1, width: 0.1, height: 0.2)
        #expect(place.rect(right) == CGRect(x: 20, y: 30, width: 20, height: 60), "x′ = (x − 0.5) × page width")
        #expect(OCRTextLayer.isShown(right, in: 0.5...1))
        #expect(!OCRTextLayer.isShown(right, in: 0...0.5))
        // Across the gutter: in the half holding its middle only, so it can't be tapped through the other.
        let gutter = NormalizedRect(x: 0.45, y: 0.1, width: 0.2, height: 0.2)   // middle at 0.55
        #expect(OCRTextLayer.isShown(gutter, in: 0.5...1))
        #expect(!OCRTextLayer.isShown(gutter, in: 0...0.5))
        let whole = OCRTextLayer.Placement(layer: CGSize(width: 200, height: 300), visible: 0...1)
        #expect(whole.rect(right) == right.pixels(in: CGSize(width: 200, height: 300)), "a whole page as before")
    }
}
