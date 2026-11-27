import AetherBridge
import Foundation
import PlayerKit
import Testing

/// AetherEngine behind `PlayerEngine` on a real video (opt-in, muted):
/// `TEST_RUNNER_AETHER_TEST_VIDEO=<file> TEST_RUNNER_UITEST_MUTE=1`, with the 60 s video from
/// scripts/make-test-media.sh. Prints how close a line-pause boundary stops.
@MainActor @Suite struct AetherPlayerEngineTests {
    nonisolated static let video = ProcessInfo.processInfo.environment["AETHER_TEST_VIDEO"]
    nonisolated static let muted = ProcessInfo.processInfo.environment["UITEST_MUTE"] != nil

    @Test(.enabled(if: video != nil && muted))
    func playsPausesAtABoundaryAndSeeks() async throws {
        let engine = try AetherPlayerEngine()
        defer { engine.shutdown() }
        engine.load(URL(filePath: Self.video!), headers: [:], start: 5)
        engine.setPaused(false)
        for second in 0..<15 where !(engine.hasStarted && !engine.isPaused && engine.timePosition > 5.5) {
            print("AetherEngine \(second) s: started \(engine.hasStarted), paused \(engine.isPaused), time \(engine.timePosition), clock \(engine.clockTime), route \(engine.route), error \(engine.lastError ?? "-")")
            try await Task.sleep(for: .seconds(1))
        }
        try await wait(1) { engine.hasStarted && !engine.isPaused && engine.timePosition > 5.5 }
        #expect(abs(engine.duration - 60) < 1, "the 60 s test video")
        #expect(engine.tracks.contains { $0.type == "audio" })
        #expect(engine.videoAspect.map { abs($0 - 16.0 / 9) < 0.01 } == true)

        for speed in [1.0, 2.0] {
            engine.setSpeed(speed)
            engine.setPaused(false)
            try await wait(5) { !engine.isPaused }
            let target = engine.timePosition + 1.5
            var reported: Double?
            engine.setTimeBoundary(target) {
                reported = engine.timePosition
                engine.setPaused(true)
            }
            try await wait(6) { reported != nil }
            try await Task.sleep(for: .milliseconds(400))
            let stopped = engine.clockTime
            print("AetherEngine boundary at \(speed)× (\(engine.route) route): stopped \(Int(((stopped - target) * 1000).rounded())) ms past it")
            #expect(reported == target || reported! >= target, "never before the boundary")
            #expect(engine.isPaused)
            #expect(stopped - target < 0.25 * speed, "stops close to the boundary")
        }

        engine.setSpeed(1)
        engine.seek(to: 30)
        try await wait(8) { abs(engine.timePosition - 30) < 0.5 }
        #expect(abs(engine.timePosition - 30) < 0.5)
    }

    private func wait(_ timeout: Double, _ condition: @MainActor () -> Bool) async throws {
        let started = Date()
        while !condition() {
            guard Date().timeIntervalSince(started) < timeout else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
