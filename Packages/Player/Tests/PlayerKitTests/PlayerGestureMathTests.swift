import Foundation
@testable import PlayerKit
import Testing

@Suite struct PlayerGestureMathTests {
    @Test func thirdsAndEdges() {
        #expect(PlayerGestureMath.third(x: 50, width: 900) == .left)
        #expect(PlayerGestureMath.third(x: 450, width: 900) == .middle)
        #expect(PlayerGestureMath.third(x: 899, width: 900) == .right)
        #expect(PlayerGestureMath.edge(x: 100, width: 900) == .left)
        #expect(PlayerGestureMath.edge(x: 450, width: 900) == nil)
        #expect(PlayerGestureMath.edge(x: 800, width: 900) == .right)
    }

    @Test func scrubScalesWithLengthAndClamps() {
        // A 24-minute episode: a full-width drag is 90 s.
        #expect(PlayerGestureMath.scrubTarget(from: 600, dx: 450, width: 900, duration: 1440) == 645)
        #expect(PlayerGestureMath.scrubTarget(from: 10, dx: -900, width: 900, duration: 1440) == 0)
        #expect(PlayerGestureMath.scrubTarget(from: 1430, dx: 900, width: 900, duration: 1440) == 1440)
        // A 60 s clip: 15 s per width.
        #expect(PlayerGestureMath.secondsPerWidth(duration: 60) == 15)
        #expect(PlayerGestureMath.secondsPerWidth(duration: 20) == 10)
    }

    @Test func levelsFollowVerticalDrags() {
        #expect(PlayerGestureMath.level(from: 0.5, dy: -160, height: 400) == 1)
        #expect(abs(PlayerGestureMath.level(from: 0.5, dy: 80, height: 400) - 0.25) < 0.0001)
    }

    @Test func doubleTapsAddUpOnTheSameSide() {
        var skip = SkipAccumulator()
        let start = Date(timeIntervalSince1970: 0)
        #expect(skip.register(.left, at: start) == -10 && skip.total == -10)
        #expect(skip.register(.left, at: start.addingTimeInterval(0.5)) == -10 && skip.total == -20)
        // Too late, or the other side: starts over.
        _ = skip.register(.left, at: start.addingTimeInterval(3))
        #expect(skip.total == -10)
        _ = skip.register(.right, at: start.addingTimeInterval(3.2))
        #expect(skip.total == 10)
        #expect(skip.register(.middle, at: start.addingTimeInterval(3.3)) == 0)
    }
}
