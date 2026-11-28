import Foundation
@testable import PlayerKit
import Testing

/// How close mpv pauses to a time boundary (Pause After Each Line), measured on a real video:
/// `MPV_PAUSE_TIMING_VIDEO=<local file> UITEST_MUTE=1 swift test --filter LinePauseTimingTests`.
/// Skipped without the video. Prints the overshoot at 1× and 2×.
@MainActor @Suite struct LinePauseTimingTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MPV_PAUSE_TIMING_VIDEO"] != nil))
    func pausesCloseToTheBoundary() async throws {
        let video = URL(filePath: ProcessInfo.processInfo.environment["MPV_PAUSE_TIMING_VIDEO"]!)
        let mpv = MPVController()
        defer { mpv.shutdown() }
        mpv.load(video, headers: [:], start: 5)
        mpv.setPaused(false)
        try await wait(timeout: 10) { mpv.hasStarted && mpv.timePosition > 5 }

        // On a frame (whole seconds at 24 fps, as the spike lab measured), and between frames:
        // mpv's time moves once a frame, so it can't stop closer than the next one.
        for (speed, offset) in [(1.0, 2.0), (2.0, 2.0), (1.0, 2.013), (2.0, 2.013)] {
            mpv.setSpeed(speed)
            var atFire: [Double] = []
            var stopped: [Double] = []
            for round in 0..<8 {
                let start = 10 + Double(round) * 12
                mpv.seek(to: start)
                try await wait(timeout: 5) { abs(mpv.timePosition - start) < 0.2 }
                mpv.setPaused(false)
                try await wait(timeout: 5) { !mpv.isPaused && mpv.timePosition > start + 0.2 }
                let target = start + offset
                var fired: Double?
                mpv.setTimeBoundary(target) {
                    fired = mpv.timePosition
                    mpv.setPaused(true)
                }
                try await wait(timeout: 6) { fired != nil }
                try await Task.sleep(for: .milliseconds(300))
                atFire.append((fired! - target) * 1000)
                stopped.append((mpv.timePosition - target) * 1000)
            }
            func summary(_ values: [Double]) -> String {
                let sorted = values.sorted()
                return String(format: "median %.1f ms, min %.1f, max %.1f", sorted[sorted.count / 2], sorted.first!, sorted.last!)
            }
            print("pause timing \(speed)×, target \(offset == 2 ? "on a frame" : "between frames"): time at the callback past the boundary: \(summary(atFire)); stopped at: \(summary(stopped))")
            #expect(atFire.allSatisfy { $0 >= 0 }, "never before the boundary")
        }
    }

    private func wait(timeout: Double, _ condition: @MainActor () -> Bool) async throws {
        let started = Date()
        while !condition() {
            guard Date().timeIntervalSince(started) < timeout else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(2))
        }
    }
}
