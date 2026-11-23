import CoreGraphics
@testable import PlayerKit
import Testing

@Suite struct VideoFrameTests {
    @Test func fillsBoundsUntilTheShapeIsKnown() {
        let bounds = CGRect(x: 0, y: 0, width: 393, height: 852)
        #expect(videoFrame(in: bounds, aspect: nil) == bounds)
    }

    @Test func keepsTheVideoShapeInBothOrientations() {
        let portrait = videoFrame(in: CGRect(x: 0, y: 0, width: 393, height: 852), aspect: 16.0 / 9)
        #expect(portrait.width == 393)
        #expect(abs(portrait.height - 221) <= 1)
        #expect(abs(portrait.midY - 426) <= 1)
        let landscape = videoFrame(in: CGRect(x: 0, y: 0, width: 852, height: 393), aspect: 16.0 / 9)
        #expect(landscape.height == 393)
        #expect(abs(landscape.width - 699) <= 1)
        #expect(abs(landscape.width / landscape.height - portrait.width / portrait.height) < 0.001)
    }

    @Test func fillingCoversTheViewWithTheVideosShape() {
        // A 16:9 picture on a phone held sideways (wider than 16:9): as wide as the screen,
        // taller than it, centred, cropped top and bottom.
        let bounds = CGRect(x: 0, y: 0, width: 874, height: 402)
        let filled = videoFrame(in: bounds, aspect: 16.0 / 9, fills: true)
        #expect(abs(filled.width - 874) < 0.5)
        #expect(abs(filled.width / filled.height - 16.0 / 9) < 0.001, "never squashed")
        #expect(filled.minY < 0 && abs(filled.midY - bounds.midY) < 0.5)
        #expect(filled.contains(bounds.insetBy(dx: 0.5, dy: 0.5)))
        // A 4:3 picture: cropped the same way. Unknown shape: the whole view, as when fitting.
        #expect(abs(videoFrame(in: bounds, aspect: 4.0 / 3, fills: true).width - 874) < 0.5)
        #expect(videoFrame(in: bounds, aspect: nil, fills: true) == bounds)
    }
}
