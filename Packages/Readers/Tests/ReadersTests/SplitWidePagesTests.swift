import Core
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

    @Test func onlyAPortraitReaderWithoutSpreadsSplits() {
        func splits(portrait: Bool, spreads: MangaReaderSettings.Spreads, on: Bool = true) -> Bool {
            var settings = MangaReaderSettings()
            settings.spreads = spreads
            settings.splitsWidePages = on
            return MangaReaderModel.splitsWide(settings: settings, portrait: portrait, spreadsFitScreen: !portrait)
        }
        #expect(splits(portrait: true, spreads: .auto), "portrait, Automatic (no spreads there): split")
        #expect(splits(portrait: true, spreads: .off))
        #expect(!splits(portrait: true, spreads: .on), "spreads forced on: the wide page whole, at the pages' scale")
        #expect(!splits(portrait: false, spreads: .off), "landscape: whole, spreads or not")
        #expect(!splits(portrait: false, spreads: .auto))
        #expect(!splits(portrait: true, spreads: .auto, on: false), "the setting off")
    }

    @Test func movingBetweenHalvesIsNotAPageMove() {
        let first = ReaderSlot(pages: [2], half: .first), second = ReaderSlot(pages: [2], half: .second)
        #expect(SpreadLayout.isHalfMove(from: first, to: second))
        #expect(SpreadLayout.isHalfMove(from: second, to: first))
        #expect(!SpreadLayout.isHalfMove(from: second, to: ReaderSlot(pages: [3])))
        #expect(!SpreadLayout.isHalfMove(from: ReaderSlot(pages: [1]), to: first))
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
        let place = OCRTextLayer.Placement(layer: CGSize(width: 100, height: 300), shown: CGRect(x: 0.5, y: 0, width: 0.5, height: 1))
        #expect(place.page == CGSize(width: 200, height: 300))
        let right = NormalizedRect(x: 0.6, y: 0.1, width: 0.1, height: 0.2)
        #expect(place.rect(right) == CGRect(x: 20, y: 30, width: 20, height: 60), "x′ = (x − 0.5) × page width")
        #expect(OCRTextLayer.isShown(right, in: CGRect(x: 0.5, y: 0, width: 0.5, height: 1)))
        #expect(!OCRTextLayer.isShown(right, in: CGRect(x: 0, y: 0, width: 0.5, height: 1)))
        // Across the gutter: in the half holding its middle only, so it can't be tapped through the other.
        let gutter = NormalizedRect(x: 0.45, y: 0.1, width: 0.2, height: 0.2)   // middle at 0.55
        #expect(OCRTextLayer.isShown(gutter, in: CGRect(x: 0.5, y: 0, width: 0.5, height: 1)))
        #expect(!OCRTextLayer.isShown(gutter, in: CGRect(x: 0, y: 0, width: 0.5, height: 1)))
        let whole = OCRTextLayer.Placement(layer: CGSize(width: 200, height: 300), shown: OCRTextLayer.whole)
        #expect(whole.rect(right) == right.pixels(in: CGSize(width: 200, height: 300)), "a whole page as before")
    }

    /// Crop Borders: a cropped page's layer covers its middle, and boxes move up and left.
    @Test func aCroppedPageMapsItsBlocks() {
        let place = OCRTextLayer.Placement(layer: CGSize(width: 160, height: 240), shown: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8))
        #expect(place.page == CGSize(width: 200, height: 300))
        let box = NormalizedRect(x: 0.5, y: 0.5, width: 0.1, height: 0.1)
        #expect(place.rect(box) == CGRect(x: 80, y: 120, width: 20, height: 30))
        #expect(OCRTextLayer.isShown(box, in: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)))
    }
}
