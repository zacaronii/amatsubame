import Foundation
import KikuWatchLink
import Observation
import WatchConnectivity
import WatchKit
import WidgetKit

/// The watch's link to Kiku on the iPhone (docs/watch.md): the playing state it receives, and the
/// buttons it sends. Nothing here talks to a server; the phone does everything.
@MainActor @Observable
final class WatchSession: NSObject, WCSessionDelegate {
    /// The brief card after a mark.
    struct Confirmation: Identifiable, Equatable {
        let id = UUID()
        var title: String
        var detail: String
    }

    static let complicationKind = "KikuNowPlaying"

    /// The phone's state: nil until it's heard from (or kept from last time).
    private(set) var state: WatchState?
    private(set) var isReachable = false
    /// Shown for 2.5 s after a mark.
    private(set) var confirmation: Confirmation? {
        didSet {
            guard let id = confirmation?.id else { return }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(2.5))
                if self?.confirmation?.id == id { self?.confirmation = nil }
            }
        }
    }
    /// A short line under the buttons ("Your iPhone is out of reach"), cleared after a moment.
    private(set) var notice: String?
    @ObservationIgnored private var noticeReset: UUID?

    var nowPlaying: WatchNowPlaying? { state?.nowPlaying }

    func start() {
        state = WatchStateStore.load()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    // MARK: Buttons

    func send(_ command: WatchCommand) {
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else {
            unreachable(command)
            return
        }
        // Both handlers run on WatchConnectivity's queue, not the main actor.
        session.sendMessage(WatchMessages.message(command)) { @Sendable [weak self] message in
            let reply = WatchMessages.reply(from: message)
            Task { @MainActor in self?.replied(reply, to: command) }
        } errorHandler: { @Sendable [weak self] _ in
            Task { @MainActor in self?.unreachable(command) }
        }
    }

    private func replied(_ reply: WatchReply?, to command: WatchCommand) {
        guard let reply else { return }
        apply(reply.state)
        if command == .mark {
            if let time = reply.markedAt {
                WKInterfaceDevice.current().play(.success)
                confirmation = Confirmation(title: "Marked \(time.watchClock)", detail: "Mine it later in Marks on your iPhone.")
            } else {
                WKInterfaceDevice.current().play(.failure)
                show(reply.message ?? "Nothing is playing")
            }
        }
    }

    /// Out of reach: a mark waits for the phone (at the place worked out here); the rest can't.
    private func unreachable(_ command: WatchCommand) {
        guard command == .mark, let playing = nowPlaying else {
            show("Your iPhone is out of reach")
            return
        }
        let mark = WatchQueuedMark(playing, at: .now)
        WCSession.default.transferUserInfo(WatchMessages.userInfo(mark))
        WKInterfaceDevice.current().play(.success)
        confirmation = Confirmation(title: "Marked \(mark.position.watchClock)", detail: "Will mark when your iPhone is near.")
    }

    private func show(_ text: String) {
        notice = text
        let id = UUID()
        noticeReset = id
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, noticeReset == id else { return }
            notice = nil
        }
    }

    // MARK: State

    private func apply(_ newState: WatchState) {
        let changed = state?.nowPlaying?.key != newState.nowPlaying?.key
            || state?.nowPlaying?.isPlaying != newState.nowPlaying?.isPlaying
            || state?.nowPlaying?.chapter != newState.nowPlaying?.chapter
            || state?.nowPlaying?.position != newState.nowPlaying?.position
        state = newState
        WatchStateStore.save(newState)
        // Only on real changes (play, pause, seek, another episode): the complication's budget is small.
        if changed { WidgetCenter.shared.reloadTimelines(ofKind: Self.complicationKind) }
    }

    // MARK: WCSessionDelegate

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: (any Error)?) {
        let state = WatchMessages.state(from: session.receivedApplicationContext)
        let reachable = session.isReachable
        Task { @MainActor in
            self.isReachable = reachable
            if let state { self.apply(state) }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let state = WatchMessages.state(from: applicationContext) else { return }
        Task { @MainActor in self.apply(state) }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in self.isReachable = reachable }
    }
}
