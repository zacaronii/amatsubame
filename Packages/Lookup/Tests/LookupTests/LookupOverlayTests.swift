import CoreGraphics
@testable import Lookup
import Testing

@Suite struct LookupOverlayPlacementTests {
    let window = CGRect(x: 0, y: 0, width: 1200, height: 800)

    @Test func narrowScreensGetABottomPanel() {
        #expect(LookupOverlayPlacement.usesBottomPanel(CGSize(width: 402, height: 874)))
        #expect(!LookupOverlayPlacement.usesBottomPanel(CGSize(width: 874, height: 402)))
        #expect(!LookupOverlayPlacement.usesBottomPanel(window.size))
    }

    @Test func belowTheWordWhenItFits() {
        let word = CGRect(x: 300, y: 100, width: 40, height: 30)
        let card = LookupOverlayPlacement.cardFrame(anchor: word, in: window)
        #expect(card.minY == word.maxY + LookupOverlayPlacement.gap)
        #expect(card.size == LookupOverlayPlacement.cardSize)
        #expect(card.midX == word.midX)
    }

    @Test func aboveASubtitleNearTheBottom() {
        let word = CGRect(x: 600, y: 700, width: 40, height: 40)
        let card = LookupOverlayPlacement.cardFrame(anchor: word, in: window)
        #expect(card.maxY == word.minY - LookupOverlayPlacement.gap, "never covers the word")
        #expect(card.height == LookupOverlayPlacement.cardSize.height)
    }

    @Test func shorterOnTheRoomierSideAndKeptInside() {
        // A landscape phone: 300 pt above the word, less below.
        let phone = CGRect(x: 0, y: 0, width: 874, height: 402)
        let word = CGRect(x: 850, y: 320, width: 30, height: 30)
        let card = LookupOverlayPlacement.cardFrame(anchor: word, in: phone)
        #expect(card.maxY == word.minY - LookupOverlayPlacement.gap)
        #expect(card.minY >= LookupOverlayPlacement.margin)
        #expect(card.maxX <= phone.maxX - LookupOverlayPlacement.margin, "pushed in from the edge")
    }

    @Test func withoutAWordAlongTheBottom() {
        let card = LookupOverlayPlacement.cardFrame(anchor: nil, in: window)
        #expect(card.maxY == window.maxY - LookupOverlayPlacement.margin)
        #expect(card.midX == window.midX)
    }
}

@Suite struct LookupOverlayBesideTests {
    @Test func besideVerticalTextAwayFromTheNearerEdge() {
        let page = CGRect(x: 0, y: 0, width: 820, height: 1180)
        let rightColumn = CGRect(x: 600, y: 300, width: 30, height: 30)
        let card = LookupOverlayPlacement.cardFrame(anchor: rightColumn, in: page, beside: true)
        #expect(card.maxX == rightColumn.minX - LookupOverlayPlacement.gap, "left of a word in the right half")
        #expect(card.minY <= rightColumn.minY && card.maxY >= rightColumn.maxY)
        let leftColumn = CGRect(x: 100, y: 300, width: 30, height: 30)
        #expect(LookupOverlayPlacement.cardFrame(anchor: leftColumn, in: page, beside: true).minX == leftColumn.maxX + LookupOverlayPlacement.gap)
    }
}
