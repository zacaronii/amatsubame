import CoreGraphics
@testable import Miru
import Testing

/// Which player layout each screen gets, with the sizes the simulators report.
@Suite struct PlayerLayoutTests {
    func layout(_ width: CGFloat, _ height: CGFloat, insets: (top: CGFloat, left: CGFloat, bottom: CGFloat, right: CGFloat) = (0, 0, 0, 0),
                aspect: Double? = 16 / 9, fold: CGRect? = nil) -> PlayerLayout {
        let screen = CGRect(x: 0, y: 0, width: width, height: height)
        let safe = CGRect(x: insets.left, y: insets.top, width: width - insets.left - insets.right, height: height - insets.top - insets.bottom)
        return PlayerLayout.make(screen: screen, safe: safe, aspect: aspect, fold: fold)
    }

    @Test func phoneSidewaysKeepsTheControlsOverThePicture() {
        // iPhone 17 Pro Max in landscape: a 16:9 picture fills the height, no bars.
        #expect(layout(956, 440, insets: (0, 62, 21, 62)) == .overlay)
    }

    @Test func duoOpenSidewaysPutsTheControlsInTheBars() {
        // Inner screen in landscape, the crease down the middle: 951 × 535 picture, 67 pt bars.
        guard case .bars(let video, let top, let bottom) = layout(951, 669, insets: (0, 0, 20, 84),
                                                                   fold: CGRect(x: 455, y: 0, width: 41, height: 669)) else {
            Issue.record("expected bars")
            return
        }
        #expect(video.width == 951)
        #expect(top.height >= PlayerLayout.minimumBar && bottom.height >= PlayerLayout.minimumBar)
    }

    @Test func iPadSidewaysUsesBarsWhenTheyFit() {
        // iPad Pro 11" (1210 × 834): bars of about 77 pt. A 4:3 picture fills the screen instead.
        if case .bars = layout(1210, 834, insets: (24, 0, 20, 0)) {} else { Issue.record("expected bars") }
        #expect(layout(1210, 834, aspect: 4 / 3) == .overlay)
    }

    @Test func portraitPutsTheLinesUnderThePicture() {
        // iPhone 17 Pro Max in portrait.
        guard case .split(let video, let panel) = layout(440, 956, insets: (62, 0, 34, 0)) else {
            Issue.record("expected split")
            return
        }
        #expect(video.minY == 62 && video.width == 440)
        #expect(panel.minY == video.maxY && panel.maxY == 956 - 34)
    }

    @Test func aFoldAcrossSplitsAtTheFold() {
        // Inner screen in portrait (half open like a laptop, or flat): the picture above the crease.
        guard case .split(let video, let panel) = layout(669, 951, insets: (59, 0, 20, 0),
                                                         fold: CGRect(x: 0, y: 455, width: 669, height: 41)) else {
            Issue.record("expected split")
            return
        }
        #expect(video.maxY <= 455)
        #expect(panel.minY == 496)
    }

    @Test func tooShortForTheLinesKeepsTheOverlay() {
        #expect(layout(500, 520) == .overlay)
    }
}
