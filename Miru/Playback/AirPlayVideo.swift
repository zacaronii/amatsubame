import Foundation

/// The player AirPlay video plays through (AVPlayer with external playback in the app, a fake
/// in tests). The TV fetches the stream itself; this side only steers it.
@MainActor protocol AirPlayVideoPlayer: PiPPlayer {
    /// The picture is on the TV (the receiver shows video, not just the sound).
    var isExternalPlaybackActive: Bool { get }
    /// The item failed (the TV couldn't play it).
    var hasFailed: Bool { get }
    var isMuted: Bool { get set }
    func seek(to seconds: Double)
}

/// Hands playback from mpv to a TV over AirPlay and back. mpv plays on while a source gets
/// ready (`PictureInPictureHandoff`, the same sources picture in picture uses); then the
/// receiver has to show the picture, or it's a speaker and mpv keeps the sound. While the TV
/// plays, `watch` tells when it's gone back to this device, or failed or stalled (most often:
/// the TV can't reach the server), so mpv takes over again.
@MainActor
final class AirPlayVideoHandoff {
    enum Start: Equatable {
        case playing(PiPSource)
        /// The receiver plays only sound (a speaker): mpv goes on as it was.
        case soundOnly
        /// No source got ready (or the TV couldn't load one).
        case failed
    }

    enum End: Equatable {
        /// The picture left the TV (another route was picked).
        case back
        /// The TV failed, or stood still while meant to play.
        case unreachable
    }

    let player: AirPlayVideoPlayer
    private let handoff: PictureInPictureHandoff
    /// How long a ready item gets to reach the TV, paused and then playing muted.
    var tvCheck: Duration = .seconds(3)
    /// How long the time may stand still while the TV is meant to play.
    var stallLimit: Duration = .seconds(15)
    /// How long the picture may be off the TV before it counts as gone back.
    var awayLimit: Duration = .seconds(1)
    var poll: Duration = .milliseconds(250)

    init(player: AirPlayVideoPlayer, timeout: Duration = .seconds(20), stopTranscode: @escaping (String) -> Void) {
        self.player = player
        handoff = PictureInPictureHandoff(player: player, timeout: timeout, stopTranscode: stopTranscode)
    }

    /// Gets the first source that's ready at `time`, then waits for the receiver to take the
    /// picture: paused first, then playing muted (mpv still has the sound meanwhile).
    func start(at time: Double, sources: [PictureInPictureHandoff.SourceMaker]) async -> Start {
        guard let source = await handoff.start(at: time, sources: sources) else { return .failed }
        var onTV = await reachesTV()
        if !onTV, !player.hasFailed {
            player.isMuted = true
            player.play(rate: 1)
            onTV = await reachesTV()
            player.pause()
            player.isMuted = false
        }
        guard onTV, !player.hasFailed, !Task.isCancelled else {
            let failed = player.hasFailed
            _ = handoff.finish()
            return failed ? .failed : .soundOnly
        }
        return .playing(source)
    }

    private func reachesTV() async -> Bool {
        let deadline = ContinuousClock.now + tvCheck
        while !player.isExternalPlaybackActive, !player.hasFailed, ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: poll)
        }
        return player.isExternalPlaybackActive
    }

    /// While the TV plays: returns when the picture has left it, or it failed or stalled; nil
    /// when cancelled.
    func watch() async -> End? {
        var last = player.currentTime
        var lastMove = ContinuousClock.now
        var away: ContinuousClock.Instant?
        while !Task.isCancelled {
            try? await Task.sleep(for: poll)
            guard !Task.isCancelled else { return nil }
            if player.hasFailed { return .unreachable }
            let now = ContinuousClock.now
            if player.isExternalPlaybackActive {
                away = nil
            } else {
                let since = away ?? now
                away = since
                if now - since >= awayLimit { return .back }
            }
            let time = player.currentTime
            if abs(time - last) > 0.01 || !player.isPlaying {
                last = time
                lastMove = now
            } else if now - lastMove >= stallLimit {
                return .unreachable
            }
        }
        return nil
    }

    /// Where the TV got to and whether it was playing (mpv picks up from there); the player
    /// lets go and a transcode is stopped.
    func finish() -> (time: Double, wasPlaying: Bool) {
        handoff.finish()
    }
}

#if os(iOS)
import AVFoundation
import PlayerKit

/// AVPlayer for AirPlay video: plays on the TV, and while it does it stands in for the engine
/// (`PlayerEngine.attach`), so the transport goes to it and its time drives the lines.
@MainActor
final class AVAirPlayPlayer: AVPiPPlayer, AirPlayVideoPlayer, PlayerStandIn {
    private var timeObserver: Any?
    private var rate: Float = 1

    override init() {
        super.init()
        player.allowsExternalPlayback = true
        // A mirrored screen shows mpv's picture (ExternalDisplay); this player isn't used then.
        player.usesExternalPlaybackWhileExternalScreenIsActive = false
    }

    var isExternalPlaybackActive: Bool { player.isExternalPlaybackActive }
    var hasFailed: Bool { player.currentItem?.status == .failed }
    var isMuted: Bool {
        get { player.isMuted }
        set { player.isMuted = newValue }
    }

    override func play(rate: Float) {
        self.rate = rate
        // Waits for enough to play rather than stopping again at once (the TV fetches it).
        player.rate = rate
    }

    func seek(to seconds: Double) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    // PlayerStandIn
    func setPaused(_ paused: Bool) {
        if paused { pause() } else { play(rate: rate) }
    }

    func setSpeed(_ speed: Double) {
        rate = Float(speed)
        if player.rate > 0 { player.rate = rate }
    }

    /// Reports the time, pause and waiting to `engine` (several times a second, and on every
    /// start, stop and jump).
    func startReporting(to engine: any PlayerEngine) {
        stopReporting()
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 20), queue: .main) { [weak self, weak engine] _ in
            MainActor.assumeIsolated {
                guard let self, let engine else { return }
                let status = self.player.timeControlStatus
                engine.standInReport(time: self.currentTime, paused: status == .paused,
                                     buffering: status == .waitingToPlayAtSpecifiedRate, ended: false)
            }
        }
    }

    func stopReporting() {
        timeObserver.map(player.removeTimeObserver)
        timeObserver = nil
    }

    override func reset() {
        stopReporting()
        super.reset()
    }
}
#endif
