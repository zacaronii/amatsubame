import Foundation
@testable import Miru
import Testing

/// The hand-off to picture in picture, with a fake player: which source plays, when it falls
/// back to mpv, and that every transcode is stopped.
@MainActor @Suite struct PictureInPictureHandoffTests {
    final class FakePlayer: PiPPlayer {
        /// Whether each kind gets ready, and how long it takes.
        var outcome: [PiPSource.Kind: (ready: Bool, after: Duration)] = [:]
        var prepared: [PiPSource.Kind] = []
        var resets = 0
        var currentTime: Double = 0
        var isPlaying = false

        func prepare(_ source: PiPSource, at time: Double) async -> Bool {
            prepared.append(source.kind)
            let (ready, after) = outcome[source.kind] ?? (false, .zero)
            try? await Task.sleep(for: after)
            if ready { currentTime = time }
            return ready
        }
        func play(rate: Float) { isPlaying = true }
        func pause() { isPlaying = false }
        func reset() { resets += 1 }
    }

    let direct = PiPSource(kind: .direct, url: URL(string: "https://jellyfin.example/Videos/E/stream?static=true")!)
    func transcode(_ id: String = "PS-1") -> PiPSource {
        PiPSource(kind: .transcode, url: URL(string: "https://jellyfin.example/videos/E/master.m3u8")!, playSessionId: id)
    }

    @Test func theDirectStreamWhenItWorks() async {
        let player = FakePlayer()
        player.outcome = [.direct: (true, .zero)]
        var stopped: [String] = []
        let handoff = PictureInPictureHandoff(player: player) { stopped.append($0) }
        let source = await handoff.start(at: 42, sources: [{ self.direct }, { self.transcode() }])
        #expect(source?.kind == .direct && player.prepared == [.direct], "the transcode isn't even asked for")
        #expect(player.currentTime == 42)
        player.play(rate: 1)
        player.currentTime = 100
        let back = handoff.finish()
        #expect(back.time == 100 && back.wasPlaying && stopped.isEmpty)
    }

    /// A direct stream that fails goes straight to the transcode, not after the timeout.
    @Test func aFailedDirectStreamGoesStraightToTheTranscode() async {
        let player = FakePlayer()
        player.outcome = [.direct: (false, .milliseconds(20)), .transcode: (true, .milliseconds(20))]
        var stopped: [String] = []
        let handoff = PictureInPictureHandoff(player: player, timeout: .seconds(5)) { stopped.append($0) }
        let started = ContinuousClock.now
        let source = await handoff.start(at: 10, sources: [{ self.direct }, { self.transcode() }])
        #expect(source?.kind == .transcode && player.prepared == [.direct, .transcode])
        #expect(ContinuousClock.now - started < .seconds(1), "no wait for the timeout")
        #expect(player.resets == 1, "the failed item let go")
        _ = handoff.finish()
        #expect(stopped == ["PS-1"], "the transcode stopped at the end")
    }

    /// A file AVPlayer can't take (no direct source offered) goes to the transcode.
    @Test func noDirectSourceUsesTheTranscode() async {
        let player = FakePlayer()
        player.outcome = [.transcode: (true, .zero)]
        let handoff = PictureInPictureHandoff(player: player) { _ in }
        let source = await handoff.start(at: 0, sources: [{ nil }, { self.transcode() }])
        #expect(source?.kind == .transcode && player.prepared == [.transcode])
    }

    @Test func bothFailingStaysWithMpvAndStopsTheTranscode() async {
        let player = FakePlayer()
        player.outcome = [.direct: (false, .zero), .transcode: (false, .zero)]
        var stopped: [String] = []
        let handoff = PictureInPictureHandoff(player: player) { stopped.append($0) }
        let source = await handoff.start(at: 5, sources: [{ self.direct }, { self.transcode("PS-2") }])
        #expect(source == nil && handoff.active == nil)
        #expect(stopped == ["PS-2"])
    }

    /// Too slow overall (a transcode that never gets ready): mpv plays on, the transcode stops.
    @Test func theTimeoutStaysWithMpv() async {
        let player = FakePlayer()
        player.outcome = [.transcode: (true, .seconds(3))]
        var stopped: [String] = []
        let handoff = PictureInPictureHandoff(player: player, timeout: .milliseconds(200)) { stopped.append($0) }
        let started = ContinuousClock.now
        let source = await handoff.start(at: 5, sources: [{ self.transcode("PS-3") }])
        #expect(source == nil)
        #expect(stopped == ["PS-3"] && player.resets >= 1)
        #expect(ContinuousClock.now - started < .seconds(3.5))
    }

    /// Closed with its × while paused: mpv gets the time and stays paused.
    @Test func finishingPausedKeepsMpvPaused() async {
        let player = FakePlayer()
        player.outcome = [.direct: (true, .zero)]
        let handoff = PictureInPictureHandoff(player: player) { _ in }
        _ = await handoff.start(at: 30, sources: [{ self.direct }])
        player.currentTime = 31.5
        let back = handoff.finish()
        #expect(back.time == 31.5 && !back.wasPlaying)
    }

    @Test(arguments: [
        ("mp4", "h264", "aac", true), ("mov,mp4,m4a", "hevc", "aac", true), ("mkv", "h264", "aac", false),
        ("mp4", "vp9", "aac", false), ("mp4", "h264", "opus", false), ("mp4", "h264", nil, true), (nil, "h264", "aac", false),
    ] as [(String?, String?, String?, Bool)])
    func whichFilesPlayDirectly(container: String?, video: String?, audio: String?, expected: Bool) {
        #expect(PictureInPictureHandoff.playsDirectly(container: container, videoCodec: video, audioCodec: audio) == expected)
    }
}
