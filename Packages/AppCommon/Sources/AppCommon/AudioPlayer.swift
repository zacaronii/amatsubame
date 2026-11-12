import AVFoundation
import MediaPlayer
import Observation
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// AVPlayer for one episode: time, rate and play state for SwiftUI, background audio, and
/// the Lock Screen / AirPods / CarPlay controls (which skip by seconds; the player's own
/// buttons jump by lines).
@MainActor @Observable
public final class AudioPlayer {
    public private(set) var currentTime: Double = 0
    public private(set) var duration: Double = 0
    public private(set) var isPlaying = false
    public private(set) var isBuffering = false
    public private(set) var failure: String?
    public var rate: Float = 1 {
        didSet {
            player.defaultRate = rate
            if isPlaying { player.rate = rate }
            updateNowPlaying()
        }
    }

    /// Every quarter second while loaded, with the time.
    @ObservationIgnored public var onTick: ((Double) -> Void)?
    @ObservationIgnored public var onEnd: (() -> Void)?
    /// The stream stopped with an error (`failure` says why), e.g. the server no longer accepts
    /// the sign-in it started with: the caller can `reload` it.
    @ObservationIgnored public var onFailure: (() -> Void)?
    /// The user pressed play or pause (here or on the Lock Screen).
    @ObservationIgnored public var onPlayStateChange: ((Bool) -> Void)?
    /// Next and previous track (AirPods double and triple press, CarPlay and steering-wheel
    /// buttons); the commands are offered only when set.
    @ObservationIgnored public var onNextTrack: (() -> Void)? {
        didSet { if !commandTargets.isEmpty { registerCommands() } }
    }
    @ObservationIgnored public var onPreviousTrack: (() -> Void)? {
        didSet { if !commandTargets.isEmpty { registerCommands() } }
    }

    @ObservationIgnored private let player = AVPlayer()
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    @ObservationIgnored private var itemObservation: NSKeyValueObservation?
    @ObservationIgnored private var notificationTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var commandTargets: [(MPRemoteCommand, Any)] = []
    @ObservationIgnored private var nowPlaying: [String: Any] = [:]

    public init() {
        player.automaticallyWaitsToMinimizeStalling = true
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 4), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time.seconds) }
        }
        statusObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            let status = player.timeControlStatus
            Task { @MainActor in self?.statusChanged(status) }
        }
    }

    /// Loads an episode and seeks to `start`; it plays when `play()` is called.
    public func load(url: URL, headers: [String: String], start: Double, title: String, show: String, artwork: CGImage? = nil) {
        failure = nil
        let asset = headers.isEmpty ? AVURLAsset(url: url) : AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        let item = AVPlayerItem(asset: asset)
        item.audioTimePitchAlgorithm = .timeDomain
        itemObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let status = item.status
            let error = item.error?.localizedDescription
            let seconds = item.duration.seconds
            Task { @MainActor in
                guard let self else { return }
                if status == .failed { self.failed(error) }
                if status == .readyToPlay, seconds.isFinite { self.duration = seconds; self.updateNowPlaying() }
            }
        }
        player.replaceCurrentItem(with: item)
        // Exactly there, as `seek` does: a loose seek can start the audio away from the time
        // reported, and the transcript then runs ahead of what's heard.
        if start > 0 { item.seek(to: CMTime(seconds: start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero, completionHandler: nil) }
        currentTime = start
        notificationTasks.forEach { $0.cancel() }
        notificationTasks = [
            Task { [weak self] in
                for await _ in NotificationCenter.default.notifications(named: AVPlayerItem.didPlayToEndTimeNotification, object: item) {
                    self?.isPlaying = false
                    self?.onEnd?()
                }
            },
            Task { [weak self] in
                for await notification in NotificationCenter.default.notifications(named: AVPlayerItem.failedToPlayToEndTimeNotification, object: item) {
                    let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? any Error
                    self?.failed(error?.localizedDescription)
                }
            },
        ]
        #if os(iOS)
        notificationTasks.append(Task { [weak self] in
            for await notification in NotificationCenter.default.notifications(named: AVAudioSession.interruptionNotification) {
                self?.interrupted(notification)
            }
        })
        #endif
        nowPlaying = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: show,
            MPMediaItemPropertyAlbumTitle: show,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let artwork { setArtwork(artwork) }
        updateNowPlaying()
        registerCommands()
    }

    public func setArtwork(_ image: CGImage) {
        nowPlaying[MPMediaItemPropertyArtwork] = Self.artwork(image)
        updateNowPlaying()
    }

    /// MediaPlayer asks for the image on its own queue, so the closure can't be main-actor.
    nonisolated private static func artwork(_ image: CGImage) -> MPMediaItemArtwork {
        #if canImport(UIKit)
        let picture = UIImage(cgImage: image)
        #else
        let picture = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        #endif
        return MPMediaItemArtwork(boundsSize: picture.size) { @Sendable _ in picture }
    }

    public func play() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        player.playImmediately(atRate: rate)
        isPlaying = true
        onPlayStateChange?(true)
        updateNowPlaying()
    }

    public func pause() {
        player.pause()
        isPlaying = false
        onPlayStateChange?(false)
        updateNowPlaying()
    }

    public func toggle() {
        isPlaying ? pause() : play()
    }

    /// Loads the same episode again from `url` (e.g. with a renewed sign-in) where it was,
    /// keeping its Lock Screen details, and plays it if it was playing.
    public func reload(url: URL, headers: [String: String]) {
        let wasPlaying = isPlaying
        let artwork = nowPlaying[MPMediaItemPropertyArtwork]
        load(url: url, headers: headers, start: currentTime,
             title: nowPlaying[MPMediaItemPropertyTitle] as? String ?? "", show: nowPlaying[MPMediaItemPropertyArtist] as? String ?? "")
        if let artwork {
            nowPlaying[MPMediaItemPropertyArtwork] = artwork
            updateNowPlaying()
        }
        if wasPlaying { play() }
    }

    /// Shows a reason the episode can't play.
    public func pauseWithError(_ message: String) {
        pause()
        failure = message
    }

    public func seek(to time: Double) {
        let target = min(max(time, 0), duration > 0 ? duration : .greatestFiniteMagnitude)
        currentTime = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        updateNowPlaying()
    }

    public func skip(by seconds: Double) {
        seek(to: currentTime + seconds)
    }

    /// Stops and lets go of the Lock Screen controls.
    public func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        isPlaying = false
        notificationTasks.forEach { $0.cancel() }
        for (command, target) in commandTargets { command.removeTarget(target) }
        commandTargets = []
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    /// Applies the Lock Screen skip intervals from Settings.
    public var skipIntervals = (backward: 15.0, forward: 30.0) {
        didSet { registerCommands() }
    }

    // MARK: Private

    private func failed(_ message: String?) {
        failure = message ?? "The episode couldn't be played."
        onFailure?()
    }

    private func tick(_ seconds: Double) {
        guard seconds.isFinite else { return }
        currentTime = seconds
        onTick?(seconds)
    }

    private func statusChanged(_ status: AVPlayer.TimeControlStatus) {
        isBuffering = status == .waitingToPlayAtSpecifiedRate
        if status == .paused, isPlaying, player.currentItem?.status == .readyToPlay, player.rate == 0 {
            // Paused by the system (a call, headphones unplugged).
            isPlaying = false
            onPlayStateChange?(false)
        }
        updateNowPlaying()
    }

    #if os(iOS)
    private func interrupted(_ notification: Notification) {
        guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              AVAudioSession.InterruptionType(rawValue: raw) == .ended,
              let options = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt,
              AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume) else { return }
        play()
    }
    #endif

    private func updateNowPlaying() {
        guard !nowPlaying.isEmpty else { return }
        var info = nowPlaying
        info[MPMediaItemPropertyPlaybackDuration] = duration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? Double(rate) : 0
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = Double(rate)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        #if os(macOS)
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
        #endif
    }

    private func registerCommands() {
        let center = MPRemoteCommandCenter.shared()
        for (command, target) in commandTargets { command.removeTarget(target) }
        commandTargets = []
        func add(_ command: MPRemoteCommand, _ action: @escaping @MainActor (MPRemoteCommandEvent) -> Void) {
            command.isEnabled = true
            let target = command.addTarget { event in
                MainActor.assumeIsolated { action(event) }
                return .success
            }
            commandTargets.append((command, target))
        }
        add(center.playCommand) { [weak self] _ in self?.play() }
        add(center.pauseCommand) { [weak self] _ in self?.pause() }
        add(center.togglePlayPauseCommand) { [weak self] _ in self?.toggle() }
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: skipIntervals.backward)]
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: skipIntervals.forward)]
        add(center.skipBackwardCommand) { [weak self] _ in self?.skip(by: -(self?.skipIntervals.backward ?? 15)) }
        add(center.skipForwardCommand) { [weak self] _ in self?.skip(by: self?.skipIntervals.forward ?? 30) }
        add(center.changePlaybackPositionCommand) { [weak self] event in
            if let event = event as? MPChangePlaybackPositionCommandEvent { self?.seek(to: event.positionTime) }
        }
        if let onNextTrack {
            add(center.nextTrackCommand) { _ in onNextTrack() }
        } else {
            center.nextTrackCommand.isEnabled = false
        }
        if let onPreviousTrack {
            add(center.previousTrackCommand) { _ in onPreviousTrack() }
        } else {
            center.previousTrackCommand.isEnabled = false
        }
    }
}

/// Plays one line on its own (the lookup's sentence bar) without moving the main player.
@MainActor @Observable
public final class ClipPlayer {
    public private(set) var isPlaying = false

    public init() {}
    @ObservationIgnored private let player = AVPlayer()
    @ObservationIgnored private var boundary: Any?

    public func play(url: URL, headers: [String: String], from start: Double, to end: Double) {
        stop()
        let asset = headers.isEmpty ? AVURLAsset(url: url) : AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
        player.seek(to: CMTime(seconds: start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        boundary = player.addBoundaryTimeObserver(forTimes: [NSValue(time: CMTime(seconds: end, preferredTimescale: 600))], queue: .main) { [weak self] in
            MainActor.assumeIsolated { self?.stop() }
        }
        player.play()
        isPlaying = true
    }

    public func stop() {
        player.pause()
        if let boundary { player.removeTimeObserver(boundary) }
        boundary = nil
        isPlaying = false
    }
}
