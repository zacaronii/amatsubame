import CoreGraphics
@testable import Readers
import Testing

/// Facing pages on the iPhone Duo's open screen, with the simulator's sizes.
@Suite struct SpreadFramesTests {
    /// The inner screen in landscape: 951 × 669, 34 pt home indicator inset, the crease 455–496.
    let size = CGSize(width: 951, height: 635)
    let fold = CGRect(x: 455, y: 0, width: 41, height: 669)
    /// The folded screen's page: 466 × 678 less its status column (84) and bottom inset (34).
    let folded = CGSize(width: 382, height: 644)

    @Test func pagesAreTheFoldedScreensPageOnEitherSideOfTheCrease() throws {
        let frames = try #require(SpreadFrames.make(size: size, insets: (0, 0, 34, 0), fold: fold, folded: folded, rightToLeft: true))
        #expect(frames.first.size == folded && frames.second.size == folded)
        // Right to left: the first page is the right one.
        #expect(frames.first.minX >= fold.maxX && frames.second.maxX <= fold.minX)
        // Room for the progress text under them, inside the screen.
        #expect(frames.first.maxY + SpreadFrames.bottomRoom <= size.height + 34)
    }

    @Test func theStatusBarDoesntMoveOrResizeThePages() throws {
        let hidden = try #require(SpreadFrames.make(size: size, insets: (0, 0, 34, 0), fold: fold, folded: folded, rightToLeft: true))
        // Shown with the controls: 20 pt off the top of the safe area.
        let shown = try #require(SpreadFrames.make(size: CGSize(width: 951, height: 615), insets: (20, 0, 34, 0),
                                                   fold: fold, folded: folded, rightToLeft: true))
        #expect(shown.first.size == hidden.first.size)
        #expect(shown.first.minY + 20 == hidden.first.minY)
        // Or in the Duo's side column: 84 pt off the right of the safe area.
        let column = try #require(SpreadFrames.make(size: CGSize(width: 867, height: 635), insets: (0, 0, 34, 84),
                                                    fold: fold, folded: folded, rightToLeft: true))
        #expect(column.first == hidden.first && column.second == hidden.second)
    }

    @Test func leftToRightBooksStartOnTheLeft() throws {
        let frames = try #require(SpreadFrames.make(size: size, insets: (0, 0, 34, 0), fold: fold, folded: folded, rightToLeft: false))
        #expect(frames.first.maxX <= fold.minX)
    }

    @Test func withoutTheFoldedSizeEachPageFillsItsHalf() throws {
        let frames = try #require(SpreadFrames.make(size: size, insets: (0, 0, 34, 0), fold: fold, folded: nil, rightToLeft: true))
        #expect(frames.first.width == 455)
        // A folded page too big for a half falls back the same way.
        let big = try #require(SpreadFrames.make(size: size, insets: (0, 0, 34, 0), fold: fold, folded: CGSize(width: 500, height: 700), rightToLeft: true))
        #expect(big.first.width == 455)
    }

    @Test func aCreaseAcrossMakesNoSpread() {
        #expect(SpreadFrames.make(size: CGSize(width: 669, height: 917), insets: (0, 0, 34, 0),
                                  fold: CGRect(x: 0, y: 455, width: 669, height: 41), folded: folded, rightToLeft: true) == nil)
    }
}

/// Where the progress bar along the bottom edge stops for the screen's rounded corners.
@Suite struct ReaderProgressBarTests {
    @Test func stopsWhereTheCornerCrossesTheBar() {
        // A 55 pt corner (iPhone Pro Max) is still 39 pt in from the side 2.5 pt up.
        #expect(ReaderProgressBar.cornerInset(radius: 55) == 39)
        #expect(ReaderProgressBar.cornerInset(radius: 0) == 0)
    }
}

@Suite struct DeviceShapeTests {
    @Test func cornerRadiiComeFromTheScreenSizeEitherWayRound() {
        #if os(iOS)
        #expect(ReaderProgressBar.cornerRadius(screen: CGSize(width: 430, height: 932)) == 55)
        #expect(ReaderProgressBar.cornerRadius(screen: CGSize(width: 932, height: 430)) == 55)
        #expect(ReaderProgressBar.cornerRadius(screen: CGSize(width: 375, height: 667)) == 0)
        #expect(ReaderProgressBar.cornerRadius(screen: CGSize(width: 500, height: 900)) == 40)
        #else
        #expect(ReaderProgressBar.cornerRadius(screen: CGSize(width: 430, height: 932)) == 0)
        #endif
    }

    @Test func theDuoKnowsItsFoldedPage() {
        #expect(SpreadFrames.knownFoldedPage(openScreen: CGSize(width: 951, height: 669)) == CGSize(width: 382, height: 644))
        #expect(SpreadFrames.knownFoldedPage(openScreen: CGSize(width: 1024, height: 768)) == nil)
    }
}
