import AVFoundation
import Foundation
import KikuWatchLink
import MediaPlayer
import Observation

/// Plays what's on this watch (docs/KIKU_PLAN.md milestone 2, #127): a long-form audio session,
/// so watchOS routes it to headphones (and asks for them when none are connected), with Now
/// Playing and the remote commands. Each item's place is kept here (`WatchPlaces`) and goes
/// back to the phone with milestone 3.
@MainActor @Observable
final class WatchPlayer {
    private(set) var item: WatchItem?
    private(set) var isPlaying = false
    private(set) var rate: Double = 1
    /// Set when watchOS couldn't route the audio (no headphones chosen).
    private(set) var problem: String?

    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored let places = WatchPlaces()
    @ObservationIgnored private var commandsSet = false
    /// The position when nothing is loaded yet, and while a seek settles.
    @ObservationIgnored private var lastPosition: Double = 0
    @ObservationIgnored private var sampledAt = Date()

    var skipBackward: Double = 15
    var skipForward: Double = 30

    /// The playing state in the remote's own terms, so Now Playing draws both modes alike.
    var nowPlaying: WatchNowPlaying? {
        guard let item else { return nil }
        return WatchNowPlaying(itemId: item.itemId, episodeId: item.episodeId, title: item.title, subtitle: item.subtitle,
                               chapter: chapter(at: lastPosition)?.title, position: lastPosition, duration: item.duration,
                               rate: rate, isPlaying: isPlaying, sampledAt: sampledAt,
                               skipBackward: skipBackward, skipForward: skipForward)
    }

    // MARK: Loading

    /// Loads an item from its file, at its last place here, and plays it.
    func play(_ item: WatchItem, file: URL) async {
        if self.item?.key == item.key, player != nil {
            await resume()
            return
        }
        stop()
        self.item = item
        let player = AVPlayer(url: file)
        player.automaticallyWaitsToMinimizeStalling = false
        self.player = player
        let start = places.position(item.key)
        lastPosition = start
        sampledAt = .now
        if start > 0 { await player.seek(to: CMTime(seconds: start, preferredTimescale: 600)) }
        observe(player)
        setUpCommands()
        await resume()
    }

    func stop() {
        savePlace()
        player?.pause()
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        timeObserver = nil
        endObserver = nil
        player = nil
        item = nil
        isPlaying = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: Controls

    func toggle() async {
        if isPlaying { pause() } else { await resume() }
    }

    func pause() {
        player?.pause()
        isPlaying = false
        sample()
        savePlace()
    }

    /// Activates the long-form session first: watchOS picks the headphones (or asks).
    func resume() async {
        guard let player else { return }
        problem = nil
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .spokenAudio, policy: .longFormAudio)
            let routed = try await session.activate()
            guard routed else {
                problem = "Connect headphones to listen on the watch"
                return
            }
        } catch {
            problem = "Couldn't start the audio: \(error.localizedDescription)"
            return
        }
        player.playImmediately(atRate: Float(rate))
        isPlaying = true
        sample()
    }

    func skip(by seconds: Double) async {
        guard let player, let item else { return }
        let target = min(max(currentTime + seconds, 0), max(item.duration - 1, 0))
        await player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
        sample()
        savePlace()
    }

    func setRate(_ rate: Double) {
        self.rate = rate
        if isPlaying { player?.rate = Float(rate) }
        sample()
    }

    var currentTime: Double {
        guard let seconds = player?.currentTime().seconds, seconds.isFinite else { return lastPosition }
        return seconds
    }

    private func chapter(at time: Double) -> WatchItem.Chapter? {
        item?.chapters.last { $0.start <= time + 0.05 }
    }

    // MARK: Following

    private func observe(_ player: AVPlayer) {
        // Every 5 s: the remote works the position out between samples, so only the place and
        // Now Playing need it.
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 5, preferredTimescale: 1), queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isPlaying else { return }
                self.sample()
                self.savePlace()
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
                                                             object: player.currentItem, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isPlaying = false
                self.sample()
                if let key = self.item?.key { self.places.finished(key) }
                self.updateNowPlaying()
            }
        }
    }

    private func sample() {
        lastPosition = currentTime
        sampledAt = .now
        updateNowPlaying()
    }

    private func savePlace() {
        guard let item, player != nil else { return }
        places.save(item.key, position: currentTime)
    }

    // MARK: Now Playing

    private func updateNowPlaying() {
        guard let item else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: item.title,
            MPMediaItemPropertyArtist: item.subtitle,
            MPMediaItemPropertyPlaybackDuration: item.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: lastPosition,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? rate : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: rate,
        ]
        if let chapter = chapter(at: lastPosition) { info[MPMediaItemPropertyAlbumTitle] = chapter.title }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func setUpCommands() {
        guard !commandsSet else { return }
        commandsSet = true
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in await self?.resume() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in await self?.toggle() }
            return .success
        }
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: skipBackward)]
        center.skipBackwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                await self.skip(by: -self.skipBackward)
            }
            return .success
        }
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: skipForward)]
        center.skipForwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                await self.skip(by: self.skipForward)
            }
            return .success
        }
    }
}

/// Each item's place on this watch, with when it was saved (milestone 3 sends them back).
final class WatchPlaces {
    struct Place: Codable, Equatable {
        var position: Double
        var updatedAt: Date
        var finished = false
    }

    private static let key = "kiku.watch.places"
    private var places: [String: Place]

    init() {
        places = UserDefaults.standard.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode([String: Place].self, from: $0) } ?? [:]
    }

    func place(_ key: String) -> Place? { places[key] }

    /// Where to start: the saved place, or the start once finished.
    func position(_ key: String) -> Double {
        guard let place = places[key], !place.finished else { return 0 }
        return place.position
    }

    func save(_ key: String, position: Double, at date: Date = .now) {
        places[key] = Place(position: position, updatedAt: date)
        write()
    }

    func finished(_ key: String, at date: Date = .now) {
        places[key] = Place(position: places[key]?.position ?? 0, updatedAt: date, finished: true)
        write()
    }

    /// The phone's place, when it's newer than this watch's.
    func adopt(_ key: String, position: Double, updatedAt: Date) {
        if let mine = places[key], mine.updatedAt >= updatedAt { return }
        places[key] = Place(position: position, updatedAt: updatedAt)
        write()
    }

    func forget(_ key: String) {
        places[key] = nil
        write()
    }

    private func write() {
        if let data = try? JSONEncoder().encode(places) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}
