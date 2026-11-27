@testable import PlayerKit
import Testing

/// Pause After Each Line's "call me at time T" (`PlayerEngine.setTimeBoundary`), as mpv's time
/// events drive it: once, going forward, never on a seek.
@MainActor @Suite struct TimeBoundaryTests {
    @Test func crossingIsForwardAndShort() {
        let boundary = TimeBoundary(time: 10, action: {})
        #expect(boundary.isCrossed(from: 9.96, to: 10.0))
        #expect(boundary.isCrossed(from: 9.9, to: 10.3))
        #expect(!boundary.isCrossed(from: 10.0, to: 10.04), "already past it")
        #expect(!boundary.isCrossed(from: 9.9, to: 9.95), "not there yet")
        #expect(!boundary.isCrossed(from: 4, to: 12), "a seek across it")
        #expect(!boundary.isCrossed(from: 12, to: 9), "backwards")
    }

    /// Through the stand-in's reports, which move mpv's time the same way its own events do.
    @Test func mpvFiresOnceWhenTheTimeCrossesIt() {
        let mpv = MPVController()
        defer { mpv.shutdown() }
        final class StandIn: PlayerStandIn {
            func setPaused(_ paused: Bool) {}
            func seek(to seconds: Double) {}
            func setSpeed(_ speed: Double) {}
        }
        let standIn = StandIn()
        mpv.attach(standIn)
        var fired: [Double] = []
        mpv.standInReport(time: 9.5, paused: false)
        mpv.setTimeBoundary(10) { fired.append(mpv.timePosition) }
        mpv.standInReport(time: 9.9, paused: false)
        #expect(fired.isEmpty)
        mpv.standInReport(time: 10.02, paused: false)
        #expect(fired == [10.02], "fired with the new time already in place")
        mpv.standInReport(time: 9.9, paused: false)
        mpv.standInReport(time: 10.05, paused: false)
        #expect(fired.count == 1, "only once")

        mpv.setTimeBoundary(20) { fired.append(mpv.timePosition) }
        mpv.standInReport(time: 25, paused: false)
        #expect(fired.count == 1, "a jump across it doesn't count")
        mpv.setTimeBoundary(30) { fired.append(mpv.timePosition) }
        mpv.setTimeBoundary(nil) { fired.append(-1) }
        mpv.standInReport(time: 29.9, paused: false)
        mpv.standInReport(time: 30.1, paused: false)
        #expect(fired.count == 1, "cleared")
    }
}
