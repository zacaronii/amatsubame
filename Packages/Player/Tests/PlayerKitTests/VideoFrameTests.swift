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
}
