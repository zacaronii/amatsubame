@testable import PlayerKit
import Testing

/// A stand-in (AirPlay video) plays in mpv's place: the transport goes to it, and what it
/// reports is mpv's time and pause until it's detached.
@MainActor @Suite struct MPVStandInTests {
    final class StandIn: PlayerStandIn {
        var paused: [Bool] = []
        var seeks: [Double] = []
        var speeds: [Double] = []
        func setPaused(_ paused: Bool) { self.paused.append(paused) }
        func seek(to seconds: Double) { seeks.append(seconds) }
        func setSpeed(_ speed: Double) { speeds.append(speed) }
    }

    @Test func theTransportGoesToTheStandIn() {
        let mpv = MPVController()
        defer { mpv.shutdown() }
        let standIn = StandIn()
        mpv.attach(standIn)
        mpv.standInReport(time: 120, paused: false)
        #expect(mpv.timePosition == 120 && !mpv.isPaused)
        mpv.togglePause()
        mpv.seek(to: 200)
        mpv.seek(by: -5)
        mpv.setSpeed(1.5)
        #expect(standIn.paused == [true] && standIn.seeks == [200, 115] && standIn.speeds == [1.5])
        mpv.standInReport(time: 121, paused: true, buffering: true, ended: true)
        #expect(mpv.isPaused && mpv.isBuffering && mpv.reachedEnd)

        mpv.detach()
        #expect(mpv.standIn == nil && !mpv.isBuffering && !mpv.reachedEnd)
        mpv.standInReport(time: 500, paused: false)
        #expect(mpv.timePosition == 121, "nothing reported once detached")
        mpv.seek(to: 10)
        #expect(standIn.seeks.count == 2, "mpv seeks for itself again")
    }
}
