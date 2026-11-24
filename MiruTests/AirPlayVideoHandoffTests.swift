import Foundation
@testable import Miru
import Testing

/// AirPlay video with a fake player: the TV takes the picture, plays, and gives it back; a
/// speaker leaves mpv the sound; a TV that can't reach the server falls back to the sound.
@MainActor @Suite struct AirPlayVideoHandoffTests {
    final class FakeTV: AirPlayVideoPlayer {
        /// Whether prepare succeeds.
        var ready = true
        /// The receiver shows video: right away, only once playing, or never (a speaker).
        enum Receiver { case tv, tvOncePlaying, speaker }
        var receiver = Receiver.tv
        /// The TV fetches the stream (time moves while playing), or can't.
        var reachesServer = true
        var hasFailed = false
        var isMuted = false
        var mutedPlays = 0
        var currentTime: Double = 0
        var isPlaying = false
        var resets = 0
        /// The picture taken back to this device.
        var leftTV = false

        var isExternalPlaybackActive: Bool {
            guard ready, !leftTV else { return false }
            switch receiver {
            case .tv: return true
            case .tvOncePlaying: return isPlaying
            case .speaker: return false
            }
        }

        func prepare(_ source: PiPSource, at time: Double) async -> Bool {
            if ready { currentTime = time }
            return ready
        }
        func play(rate: Float) {
            isPlaying = true
            if isMuted { mutedPlays += 1 }
        }
        func pause() { isPlaying = false }
        func seek(to seconds: Double) { currentTime = seconds }
        func reset() { resets += 1 }

        /// The TV plays on for a moment (when it can reach the server).
        func tick(_ seconds: Double) {
            if isPlaying, reachesServer { currentTime += seconds }
        }
    }

    let transcode = PiPSource(kind: .transcode, url: URL(string: "https://jellyfin.example/videos/E/master.m3u8")!, playSessionId: "PS-TV")

    func handoff(_ tv: FakeTV, stopped: @escaping (String) -> Void = { _ in }) -> AirPlayVideoHandoff {
        let handoff = AirPlayVideoHandoff(player: tv, timeout: .seconds(2), stopTranscode: stopped)
        handoff.tvCheck = .milliseconds(100)
        handoff.stallLimit = .milliseconds(300)
        handoff.awayLimit = .milliseconds(60)
        handoff.poll = .milliseconds(10)
        return handoff
    }

    /// Start: the TV takes the picture at mpv's time; back: mpv gets where it got to, and the
    /// transcode stops.
    @Test func theTVPlaysAndGivesItBack() async {
        let tv = FakeTV()
        var stopped: [String] = []
        let handoff = handoff(tv) { stopped.append($0) }
        let start = await handoff.start(at: 300, sources: [{ self.transcode }])
        #expect(start == .playing(transcode) && tv.currentTime == 300)
        #expect(tv.mutedPlays == 0, "a TV that takes the picture paused isn't played muted")
        tv.play(rate: 1)
        let watching = Task { await handoff.watch() }
        for _ in 0..<5 {
            try? await Task.sleep(for: .milliseconds(20))
            tv.tick(0.5)
        }
        // This device picked again: the picture leaves the TV.
        tv.leftTV = true
        #expect(await watching.value == .back)
        let back = handoff.finish()
        #expect(back.wasPlaying && back.time > 302, "mpv picks up where the TV got to")
        #expect(stopped == ["PS-TV"])
    }

    /// A receiver that takes the picture only once playing: played muted to find out, then
    /// paused again (mpv still has the sound).
    @Test func aTVThatWaitsForPlayIsFoundMuted() async {
        let tv = FakeTV()
        tv.receiver = .tvOncePlaying
        let start = await handoff(tv).start(at: 10, sources: [{ self.transcode }])
        #expect(start == .playing(transcode))
        #expect(tv.mutedPlays == 1 && !tv.isMuted && !tv.isPlaying)
    }

    /// A speaker: mpv keeps the sound, and the transcode started for it stops.
    @Test func aSpeakerLeavesMpvTheSound() async {
        let tv = FakeTV()
        tv.receiver = .speaker
        var stopped: [String] = []
        let start = await handoff(tv) { stopped.append($0) }.start(at: 10, sources: [{ self.transcode }])
        #expect(start == .soundOnly)
        #expect(stopped == ["PS-TV"] && tv.resets == 1 && !tv.isMuted)
    }

    /// No source ready (the TV couldn't load it): failed, mpv plays on.
    @Test func noSourceFails() async {
        let tv = FakeTV()
        tv.ready = false
        #expect(await handoff(tv).start(at: 10, sources: [{ self.transcode }]) == .failed)
    }

    /// The TV can't reach the server: its time stands still while it should play, and mpv
    /// takes over (the sound only).
    @Test func anUnreachableServerFallsBack() async {
        let tv = FakeTV()
        tv.reachesServer = false
        let handoff = handoff(tv)
        #expect(await handoff.start(at: 60, sources: [{ self.transcode }]) == .playing(transcode))
        tv.play(rate: 1)
        #expect(await handoff.watch() == .unreachable)
        let back = handoff.finish()
        #expect(back.time == 60)
    }

    /// The item fails on the TV: back to mpv straight away.
    @Test func aFailureFallsBack() async {
        let tv = FakeTV()
        let handoff = handoff(tv)
        handoff.stallLimit = .seconds(30)
        #expect(await handoff.start(at: 5, sources: [{ self.transcode }]) == .playing(transcode))
        tv.play(rate: 1)
        let watching = Task { await handoff.watch() }
        try? await Task.sleep(for: .milliseconds(50))
        tv.hasFailed = true
        #expect(await watching.value == .unreachable)
    }

    /// Paused on the TV for a long time isn't a stall.
    @Test func pausedIsNotStalled() async {
        let tv = FakeTV()
        let handoff = handoff(tv)
        #expect(await handoff.start(at: 5, sources: [{ self.transcode }]) == .playing(transcode))
        let watching = Task { await handoff.watch() }
        try? await Task.sleep(for: .milliseconds(600))
        watching.cancel()
        #expect(await watching.value == nil)
    }
}
