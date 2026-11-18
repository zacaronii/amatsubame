#if os(iOS)
import AVFoundation
import AppCommon
import KikuWatchLink
import UIKit
import WatchConnectivity

/// Kiku's side of Apple Watch (docs/watch.md). The iPhone stays the brain: it keeps playing, and
/// the watch is a screen and a button. This sends what's playing whenever it changes (not every
/// second: the watch works the position out) and carries out the watch's buttons.
final class WatchBridge: NSObject, WCSessionDelegate {
    private unowned let environment: KikuEnvironment
    /// What the watch was last told, so a state it can predict isn't sent again.
    private var sent: WatchState?
    /// Each item's small cover for the watch (nil while loading or when there's none).
    private var artwork: [String: Data?] = [:]
    private var started = false

    init(environment: KikuEnvironment) {
        self.environment = environment
    }

    func start() {
        guard !started, WCSession.isSupported() else { return }
        started = true
        WCSession.default.delegate = self
        WCSession.default.activate()
        follow()
    }

    // MARK: State

    /// Sends the state now, and again whenever what it's made from changes.
    private func follow() {
        let state = withObservationTracking { currentState() } onChange: { [weak self] in
            Task { @MainActor in self?.follow() }
        }
        send(state)
    }

    private func currentState() -> WatchState {
        guard let playback = environment.playback else { return WatchState(nowPlaying: nil) }
        let entry = playback.entry
        let audio = playback.audio
        return WatchState(nowPlaying: WatchNowPlaying(
            itemId: entry.itemId, episodeId: entry.episode.id, title: entry.episode.title, subtitle: entry.showTitle,
            chapter: playback.currentChapter?.title, position: audio.currentTime,
            duration: audio.duration > 0 ? audio.duration : entry.duration, rate: Double(audio.rate),
            isPlaying: audio.isPlaying, sampledAt: .now, skipBackward: audio.skipIntervals.backward,
            skipForward: audio.skipIntervals.forward, artwork: cover(entry.itemId)))
    }

    private func send(_ state: WatchState, force: Bool = false) {
        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else { return }
        if !force, let sent, isPredicted(state, by: sent) { return }
        do {
            try session.updateApplicationContext(WatchMessages.context(state))
            sent = state
        } catch {}
    }

    private func isPredicted(_ state: WatchState, by sent: WatchState) -> Bool {
        switch (sent.nowPlaying, state.nowPlaying) {
        case (nil, nil): true
        case let (old?, new?): old.predicts(new) && old.artwork == new.artwork
        default: false
        }
    }

    /// The item's cover, 100 px at most; loaded once, then the state goes out again with it.
    private func cover(_ itemId: String) -> Data? {
        if let known = artwork[itemId] { return known }
        artwork[itemId] = .some(nil)
        Task {
            guard let client = environment.audiobookshelfClient(),
                  let request = try? await client.coverRequest(itemId: itemId, width: 200),
                  let image = try? await CoverLoader.image(for: request, maxPixelSize: 100),
                  let data = UIImage(cgImage: image).jpegData(compressionQuality: 0.7) else { return }
            artwork[itemId] = data
            send(currentState())
        }
        return nil
    }

    // MARK: Commands

    private func perform(_ command: WatchCommand) -> WatchReply {
        guard let playback = environment.playback else {
            return WatchReply(message: "Nothing is playing", state: currentState())
        }
        let audio = playback.audio
        switch command {
        case .togglePlay:
            audio.toggle()
        case .skipBackward:
            audio.skip(by: -audio.skipIntervals.backward)
        case .skipForward:
            audio.skip(by: audio.skipIntervals.forward)
        case .mark:
            guard let mark = environment.mark(.watch) else {
                return WatchReply(message: "Nothing is playing", state: currentState())
            }
            // As with AirPods: a chime you hear, but never out loud through the speaker.
            if Self.playsToHeadphones { MarkChime.play() }
            return WatchReply(message: "Marked \(mark.time.clockText)", markedAt: mark.time, state: currentState())
        }
        return WatchReply(state: currentState())
    }

    /// A mark the watch made while the phone was out of reach: at the place the watch worked out.
    private func markQueued(_ queued: WatchQueuedMark) {
        environment.mark(.watch, itemId: queued.itemId, episodeId: queued.episodeId, showTitle: queued.subtitle,
                         episodeTitle: queued.title, time: queued.position)
    }

    private static var playsToHeadphones: Bool {
        let personal: Set<AVAudioSession.Port> = [.headphones, .bluetoothA2DP, .bluetoothLE, .bluetoothHFP]
        return AVAudioSession.sharedInstance().currentRoute.outputs.contains { personal.contains($0.portType) }
    }

    // MARK: WCSessionDelegate

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: (any Error)?) {
        Task { @MainActor in self.send(self.currentState(), force: true) }
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in self.send(self.currentState(), force: true) }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    /// Another watch was paired: start again with it.
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                             replyHandler: @escaping ([String: Any]) -> Void) {
        let command = WatchMessages.command(from: message)
        nonisolated(unsafe) let reply = replyHandler
        Task { @MainActor in
            guard let command else { return reply([:]) }
            reply(WatchMessages.message(self.perform(command)))
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let queued = WatchMessages.queuedMark(from: userInfo) else { return }
        Task { @MainActor in self.markQueued(queued) }
    }
}
#endif
