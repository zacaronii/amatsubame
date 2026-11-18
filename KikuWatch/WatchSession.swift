import Foundation
import KikuWatchLink
import Observation
import WatchConnectivity
import WatchKit
import WidgetKit

/// The watch's link to Kiku on the iPhone (docs/watch.md): the playing state it receives, Live
/// Text's transcripts, and the buttons it sends. Nothing here talks to a server; the phone does
/// everything.
@MainActor @Observable
final class WatchSession: NSObject, WCSessionDelegate {
    /// The brief card after a mark or a card added.
    struct Confirmation: Identifiable, Equatable {
        let id = UUID()
        var symbol = "bookmark.fill"
        var title: String
        var detail: String
    }

    /// A word tapped in Live Text: waiting for the phone (`result` nil), then its lookup.
    struct LookupState: Equatable {
        var key: String
        var line: Int
        var character: Int
        var result: WatchLookup?
    }

    static let complicationKind = "KikuNowPlaying"

    /// The phone's state: nil until it's heard from (or kept from last time).
    private(set) var state: WatchState?
    private(set) var isReachable = false
    /// Live Text's transcript for what's playing, once the phone has sent it.
    private(set) var transcript: WatchTranscript?
    private(set) var lookup: LookupState?
    /// Shown for 2.5 s after a mark or a card.
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
    @ObservationIgnored private let transcripts = WatchTranscriptStore(
        folder: URL.applicationSupportDirectory.appending(path: "LiveText"))
    /// A transcript coming from the phone in parts.
    @ObservationIgnored private var fetching: WatchTranscriptAssembly?

    var nowPlaying: WatchNowPlaying? { state?.nowPlaying }
    /// Live Text is on in Kiku's settings on the phone.
    var liveTextOn: Bool { state?.liveText ?? false }

    func start() {
        if let saved = WatchStateStore.load() { apply(saved, save: false) }
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

    func markLine(_ line: WatchTranscript.Line) {
        guard let transcript else { return }
        send(.markLine(key: transcript.key, line: line.position))
    }

    func replay(_ line: WatchTranscript.Line) {
        guard let transcript else { return }
        send(.replayLine(key: transcript.key, line: line.position))
    }

    func lookUp(_ line: WatchTranscript.Line, character: Int) {
        guard let transcript else { return }
        lookup = LookupState(key: transcript.key, line: line.position, character: character)
        send(.lookUp(key: transcript.key, line: line.position, character: character))
    }

    func addCard() {
        guard let lookup else { return }
        send(.addCard(key: lookup.key, line: lookup.line, character: lookup.character))
    }

    func closeLookup() {
        lookup = nil
    }

    private func replied(_ reply: WatchReply?, to command: WatchCommand) {
        guard let reply else { return }
        apply(reply.state)
        switch command {
        case .mark, .markLine:
            if let time = reply.markedAt {
                WKInterfaceDevice.current().play(.success)
                confirmation = Confirmation(title: "Marked \(time.watchClock)", detail: "Mine it later in Marks on your iPhone.")
            } else {
                failed(reply.message ?? "Nothing is playing")
            }
        case let .lookUp(key, line, character):
            guard lookup == LookupState(key: key, line: line, character: character) else { return }
            if let result = reply.lookup {
                lookup?.result = result
            } else {
                lookup = nil
                failed(reply.message ?? "No dictionary entry")
            }
        case .addCard:
            if reply.cardAdded == true {
                WKInterfaceDevice.current().play(.success)
                lookup = nil
                confirmation = Confirmation(symbol: "plus.circle.fill", title: "Card added", detail: reply.message ?? "")
            } else {
                failed(reply.message ?? "Couldn't add the card")
            }
        case .transcriptPart:
            guard let part = reply.transcriptPart, part.id == fetching?.id else {
                fetching = nil
                return
            }
            if let whole = fetching?.add(part) {
                fetching = nil
                received(whole)
            } else if let next = part.next {
                send(.transcriptPart(id: part.id, from: next))
            }
        case .togglePlay, .skipBackward, .skipForward, .replayLine:
            if let message = reply.message { show(message) }
        }
    }

    private func failed(_ message: String) {
        WKInterfaceDevice.current().play(.failure)
        show(message)
    }

    /// Out of reach: a mark waits for the phone (at the place worked out here); the rest can't.
    private func unreachable(_ command: WatchCommand) {
        guard let playing = nowPlaying else { return show("Your iPhone is out of reach") }
        let mark: WatchQueuedMark
        switch command {
        case .mark:
            mark = WatchQueuedMark(playing, at: .now)
        case let .markLine(key, position):
            guard key == playing.key, let line = transcript?.lines.first(where: { $0.position == position }) else {
                return show("Your iPhone is out of reach")
            }
            mark = WatchQueuedMark(line: line, of: playing, at: .now)
        case .lookUp:
            lookup = nil
            return show("Your iPhone is out of reach")
        case .transcriptPart:
            // Asked again when the phone is back.
            fetching = nil
            return
        default:
            return show("Your iPhone is out of reach")
        }
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

    private func apply(_ newState: WatchState, save: Bool = true) {
        let changed = state?.nowPlaying?.key != newState.nowPlaying?.key
            || state?.nowPlaying?.isPlaying != newState.nowPlaying?.isPlaying
            || state?.nowPlaying?.chapter != newState.nowPlaying?.chapter
            || state?.nowPlaying?.position != newState.nowPlaying?.position
        state = newState
        if save { WatchStateStore.save(newState) }
        // Only on real changes (play, pause, seek, another episode): the complication's budget is small.
        if changed && save { WidgetCenter.shared.reloadTimelines(ofKind: Self.complicationKind) }
        followTranscript()
    }

    /// The transcript the state names: from disk, or fetched from the phone in parts.
    private func followTranscript() {
        guard let id = nowPlaying?.transcript else {
            transcript = nil
            return
        }
        if transcript?.id == id { return }
        transcript = transcripts.load(id: id)
        guard transcript == nil, fetching?.id != id,
              WCSession.default.activationState == .activated, WCSession.default.isReachable else { return }
        fetching = WatchTranscriptAssembly(id: id)
        send(.transcriptPart(id: id, from: 0))
    }

    private func received(_ transcript: WatchTranscript) {
        try? transcripts.save(transcript)
        if nowPlaying?.transcript == transcript.id { self.transcript = transcript }
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
        Task { @MainActor in
            self.isReachable = reachable
            if reachable { self.followTranscript() }
        }
    }

}
