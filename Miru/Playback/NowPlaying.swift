import JellyfinKit
import MediaPlayer
#if os(iOS)
import AVFoundation
import UIKit
#else
import AppKit
#endif

/// Headphone, Lock Screen and Control Center controls while a video is open:
/// AirPods press plays or pauses, double-press goes to the next subtitle line, triple-press
/// goes back to the line before; the scrubber seeks. Also tells the system what's playing.
@MainActor
final class NowPlaying {
    private var registered: [(MPRemoteCommand, Any)] = []
    private var info: [String: Any] = [:]
    private var artworkTask: Task<Void, Never>?

    struct Actions {
        var play: @MainActor () -> Void
        var pause: @MainActor () -> Void
        var toggle: @MainActor () -> Void
        var nextLine: @MainActor () -> Void
        var lineBefore: @MainActor () -> Void
        var seek: @MainActor (Double) -> Void
    }

    /// Playback (not ambient, not mixing with others) is what makes the app the one headphone
    /// presses go to. Word audio played before a video may have left the session ducking
    /// others, which mixes. Call it before mpv loads a file: changing the session under
    /// running audio disturbs playback.
    static func prepareAudioSession() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        do {
            if session.category != .playback || session.mode != .moviePlayback || !session.categoryOptions.isEmpty {
                try session.setCategory(.playback, mode: .moviePlayback)
            }
            try session.setActive(true)
        } catch {
            NowPlayingLog.write("audio session error: \(error.localizedDescription)")
        }
        NowPlayingLog.write("audio session: \(session.category.rawValue), \(session.mode.rawValue), options \(session.categoryOptions.rawValue), other audio \(session.isOtherAudioPlaying)")
        UIApplication.shared.beginReceivingRemoteControlEvents()
        #endif
    }

    /// For the log: the audio session's options when they'd make the app mix.
    static var sessionNote: String {
        #if os(iOS)
        let options = AVAudioSession.sharedInstance().categoryOptions.rawValue
        return options == 0 ? "" : ", session options \(options) (mixing)"
        #else
        ""
        #endif
    }

    /// Takes over the system's media controls (until `stop`).
    func start(_ actions: Actions) {
        stop()
        let center = MPRemoteCommandCenter.shared()
        add(center.playCommand, "play", actions.play)
        add(center.pauseCommand, "pause", actions.pause)
        add(center.togglePlayPauseCommand, "toggle", actions.toggle)
        add(center.nextTrackCommand, "next line", actions.nextLine)
        add(center.previousTrackCommand, "line before", actions.lineBefore)
        NowPlayingLog.write("commands registered")
        center.changePlaybackPositionCommand.isEnabled = true
        let seek = actions.seek
        let target = center.changePlaybackPositionCommand.addTarget(handler: Self.handler { event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return nil }
            let position = event.positionTime
            return { seek(position) }
        })
        registered.append((center.changePlaybackPositionCommand, target))
    }

    private func add(_ command: MPRemoteCommand, _ name: String, _ action: @escaping @MainActor () -> Void) {
        command.isEnabled = true
        let target = command.addTarget(handler: Self.handler { _ in
            NowPlayingLog.write("command: \(name)")
            return action
        })
        registered.append((command, target))
    }

    /// A command handler that may be called on any thread: it hands the action to the main
    /// actor (where the player lives) and answers straight away.
    private nonisolated static func handler(
        _ action: @escaping @Sendable (MPRemoteCommandEvent) -> (@MainActor () -> Void)?
    ) -> @Sendable (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        { event in
            guard let work = action(event) else { return .commandFailed }
            let box = UncheckedAction(work)
            Task { @MainActor in box.run() }
            return .success
        }
    }

    /// The player's actions are only ever run on the main actor.
    private nonisolated struct UncheckedAction: @unchecked Sendable {
        let run: @MainActor () -> Void
        init(_ run: @escaping @MainActor () -> Void) { self.run = run }
    }

    /// What's playing: called when the item opens, on play/pause and after seeks (the system
    /// moves the position along by itself in between).
    func update(title: String, series: String?, duration: Double, position: Double, isPaused: Bool) {
        info[MPMediaItemPropertyTitle] = title
        info[MPMediaItemPropertyArtist] = series
        info[MPMediaItemPropertyAlbumTitle] = series
        info[MPMediaItemPropertyPlaybackDuration] = duration > 0 ? duration : nil
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = position
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPaused ? 0.0 : 1.0
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.video.rawValue
        let center = MPNowPlayingInfoCenter.default()
        if center.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String != title {
            NowPlayingLog.write("now playing: \(title), \(isPaused ? "paused" : "playing")")
        }
        center.nowPlayingInfo = info
        #if os(macOS)
        center.playbackState = isPaused ? .paused : .playing
        #endif
    }

    /// The episode's (or series') picture, loaded once per item.
    func loadArtwork(_ request: URLRequest?, http: @escaping @Sendable (URLRequest) async throws -> Data) {
        artworkTask?.cancel()
        guard let request else { return }
        artworkTask = Task { [weak self] in
            guard let data = try? await http(request), !Task.isCancelled, let artwork = Self.artwork(data) else { return }
            self?.info[MPMediaItemPropertyArtwork] = artwork
            if MPNowPlayingInfoCenter.default().nowPlayingInfo != nil {
                MPNowPlayingInfoCenter.default().nowPlayingInfo = self?.info
            }
        }
    }

    /// The system asks for the picture on a background queue, so nothing here is main-actor.
    private nonisolated static func artwork(_ data: Data) -> MPMediaItemArtwork? {
        #if os(iOS)
        guard let image = UIImage(data: data) else { return nil }
        let box = UncheckedImage(image: image)
        #else
        guard let image = NSImage(data: data) else { return nil }
        let box = UncheckedImage(image: image)
        #endif
        return MPMediaItemArtwork(boundsSize: image.size, requestHandler: { @Sendable _ in box.image })
    }

    /// The image is never changed after loading.
    private nonisolated struct UncheckedImage: @unchecked Sendable {
        #if os(iOS)
        let image: UIImage
        #else
        let image: NSImage
        #endif
    }

    /// Gives the controls back (the player closed or left the screen).
    func stop() {
        artworkTask?.cancel()
        for (command, target) in registered {
            command.removeTarget(target)
            command.isEnabled = false
        }
        registered = []
        info = [:]
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        #if os(macOS)
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        #endif
    }
}

/// A small log of what the system was told and asked, to read off the device with
/// devicectl: Application Support/nowplaying.log, kept under about 100 KB.
nonisolated enum NowPlayingLog {
    static let url = URL.applicationSupportDirectory.appending(path: "nowplaying.log")
    private static let queue = DispatchQueue(label: "nowplaying.log")

    static func write(_ line: String) {
        let stamped = "\(Date().formatted(.iso8601)) \(line)\n"
        queue.async {
            let manager = FileManager.default
            try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let size = try? manager.attributesOfItem(atPath: url.path(percentEncoded: false))[.size] as? Int, size > 100_000 {
                try? manager.removeItem(at: url)
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(stamped.utf8))
                try? handle.close()
            } else {
                try? Data(stamped.utf8).write(to: url)
            }
        }
    }
}
