import CoreGraphics
import Foundation
@testable import Readers
import Testing

/// Crop Borders' rule on pages drawn here (no manga in the repository): 200 × 280 in grey.
@Suite struct PageBordersTests {
    struct Page {
        var gray: [UInt8]
        let width = 200, height = 280
        init(paper: UInt8) { gray = [UInt8](repeating: paper, count: 200 * 280) }

        /// Art: busy greys, the way a panel is.
        mutating func art(_ x: Range<Int>, _ y: Range<Int>, seed: Int = 1) {
            var value = UInt64(seed)
            for row in y { for column in x {
                value = value &* 6364136223846793005 &+ 1442695040888963407
                gray[row * width + column] = UInt8(40 + (value >> 33) % 150)
            } }
        }

        mutating func set(_ x: Int, _ y: Int, _ v: UInt8) { gray[y * width + x] = v }

        /// JPEG-like noise of ± `amount` everywhere.
        mutating func noise(_ amount: Int) {
            var value: UInt64 = 7
            for index in gray.indices {
                value = value &* 6364136223846793005 &+ 1442695040888963407
                let delta = Int((value >> 33) % UInt64(2 * amount + 1)) - amount
                gray[index] = UInt8(min(max(Int(gray[index]) + delta, 0), 255))
            }
        }

        func detect() -> CGRect? { PageBorders.detect(gray: gray, width: width, height: height) }
    }

    func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.01 }

    @Test func whiteMarginsAreCroppedWithRoomGivenBack() throws {
        var page = Page(paper: 250)
        page.art(20..<180, 28..<252)
        let crop = try #require(page.detect())
        #expect(near(crop.minX, 0.1 - 0.015) && near(crop.maxX, 0.9 + 0.015))
        #expect(near(crop.minY, 0.1 - 0.015) && near(crop.maxY, 0.9 + 0.015))
    }

    @Test func blackMarginsToo() throws {
        var page = Page(paper: 8)
        page.art(16..<184, 14..<266)
        #expect(page.detect() != nil)
    }

    @Test func noiseAndASpeckDontStopTheScan() throws {
        var page = Page(paper: 245)
        page.art(20..<180, 28..<252)
        page.noise(8)
        page.set(5, 140, 0) // one dark speck in the left margin
        let crop = try #require(page.detect())
        #expect(near(crop.minX, 0.085), "\(crop)")
    }

    /// A page number in the bottom margin: the crop stops at it (less is cropped there).
    @Test func aPageNumberInTheMarginKeepsItsSide() throws {
        var page = Page(paper: 250)
        page.art(20..<180, 28..<240)
        page.art(95..<105, 262..<270, seed: 3)
        let crop = try #require(page.detect())
        #expect(crop.maxY > 0.95, "the number is kept: \(crop)")
        #expect(near(crop.minY, 0.085))
    }

    @Test func aMostlyBlankPageIsShownWhole() {
        var page = Page(paper: 250)
        page.art(70..<130, 100..<160) // a small panel in the middle
        #expect(page.detect() == nil)
        #expect(Page(paper: 250).detect() == nil, "an empty page")
    }

    @Test func greyPaperOrAGradientIsLeftAlone() {
        var grey = Page(paper: 180)
        grey.art(20..<180, 28..<252)
        #expect(grey.detect() == nil, "not near white or black")
        var gradient = Page(paper: 0)
        for y in 0..<280 { for x in 0..<200 { gradient.set(x, y, UInt8(150 + x / 2)) } }
        gradient.art(20..<180, 28..<252)
        #expect(gradient.detect() == nil, "the edge isn't one colour")
    }

    /// Art to one edge (a bleed): that side stays, the others go.
    @Test func artTouchingAnEdgeKeepsIt() throws {
        var page = Page(paper: 250)
        page.art(0..<180, 28..<252)
        let crop = try #require(page.detect())
        #expect(crop.minX == 0 && near(crop.maxX, 0.915))
    }

    @Test func tinyMarginsArentWorthIt() {
        var page = Page(paper: 250)
        page.art(2..<198, 2..<278)
        #expect(page.detect() == nil)
    }

    @Test func aSpreadSharesTopAndBottomAndKeepsTheGutter() {
        let left = CGRect(x: 0.1, y: 0.05, width: 0.85, height: 0.85)
        let right = CGRect(x: 0.02, y: 0.1, width: 0.8, height: 0.88)
        let (l, r) = PageBorders.spread(left: left, right: right)
        #expect(l.minY == 0.05 && r.minY == 0.05 && near(l.maxY, 0.98) && near(r.maxY, 0.98))
        #expect(l.maxX == 1 && r.minX == 0, "the gutter edges stay")
        #expect(l.minX == 0.1 && near(r.maxX, 0.82), "the outer edges are cropped")
        let (whole, _) = PageBorders.spread(left: nil, right: right)
        #expect(whole.minX == 0 && whole.minY == 0.0)
    }

    /// A real image through Core Graphics (the downsampling path).
    @Test func detectsOnACGImage() throws {
        let context = try #require(CGContext(data: nil, width: 800, height: 1120, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 800, height: 1120))
        for i in 0..<40 {
            context.setFillColor(CGColor(red: Double(i % 7) / 10, green: Double(i % 5) / 10, blue: 0.2, alpha: 1))
            context.fill(CGRect(x: 80 + (i % 8) * 80, y: 112 + (i / 8) * 179, width: 80, height: 179))
        }
        let image = try #require(context.makeImage())
        let crop = try #require(PageBorders.detect(image))
        #expect(near(crop.minX, 0.085) && near(crop.minY, 0.085), "\(crop)")
    }
}

/// What each of a slot's pages shows with crops found.
@Suite struct CropShownTests {
    let crop = CGRect(x: 0.1, y: 0.05, width: 0.8, height: 0.9)

    @Test func aSinglePageShowsItsCropOrAll() {
        #expect(MangaReaderModel.shown(ReaderSlot(pages: [3]), crops: [3: crop], rightToLeft: true) == [crop])
        #expect(MangaReaderModel.shown(ReaderSlot(pages: [4]), crops: [3: crop], rightToLeft: true) == [CGRect(x: 0, y: 0, width: 1, height: 1)])
    }

    /// A half of a split page: the crop within that half; its gutter edge stays.
    @Test func aHalfIsCroppedOnItsOuterSide() {
        let first = MangaReaderModel.shown(ReaderSlot(pages: [2], half: .first), crops: [2: crop], rightToLeft: true)[0]
        #expect(first.minX == 0.5 && abs(first.maxX - 0.9) < 0.0001 && first.minY == 0.05, "\(first)")
        let plain = MangaReaderModel.shown(ReaderSlot(pages: [2], half: .first), crops: [:], rightToLeft: true)[0]
        #expect(plain == CGRect(x: 0.5, y: 0, width: 0.5, height: 1))
    }

    /// A right-to-left spread: the first page is on the right, so its gutter is its left edge.
    @Test func aSpreadKeepsItsGutterInEitherDirection() {
        let shown = MangaReaderModel.shown(ReaderSlot(pages: [5, 6]), crops: [5: crop, 6: crop], rightToLeft: true)
        #expect(shown[0].minX == 0 && shown[1].maxX == 1, "page 5 on the right, page 6 on the left")
        let ltr = MangaReaderModel.shown(ReaderSlot(pages: [5, 6]), crops: [5: crop], rightToLeft: false)
        #expect(ltr[0].maxX == 1 && ltr[1].minX == 0 && ltr[0].minY == ltr[1].minY)
    }
}
