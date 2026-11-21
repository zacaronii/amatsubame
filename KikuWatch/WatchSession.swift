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
    /// One for the app and its delegate (background downloads can wake it with no window).
    static let shared = WatchSession()

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
    /// Transcripts the phone couldn't send this launch (not asked for again until the next).
    @ObservationIgnored private var unavailable: Set<String> = []
    /// A lookup paused this watch's player (Watch mode).
    @ObservationIgnored private var resumesAfterLookup = false
    /// What's on this watch (docs/KIKU_PLAN.md milestone 2).
    let downloads = WatchDownloads()
    /// Plays it (#127).
    let player = WatchPlayer()

    /// What Now Playing controls: Kiku on the iPhone, or this watch's own player.
    enum Mode: String {
        case phone, watch
    }

    private(set) var mode: Mode = Mode(rawValue: UserDefaults.standard.string(forKey: "kiku.watch.mode") ?? "") ?? .phone {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "kiku.watch.mode") }
    }

    /// What Now Playing shows: the phone's, or this watch's own in Watch mode.
    var nowPlaying: WatchNowPlaying? { mode == .watch ? player.nowPlaying : state?.nowPlaying }

    /// This watch's copy of an item's cover (Watch mode's artwork).
    private func coverForPlayer() {
        player.artwork = player.item.flatMap { downloads.covers[$0.itemId] }
    }
    /// Live Text is on in Kiku's settings on the phone. It follows whichever player Now Playing
    /// shows; in Watch mode from the transcripts kept with each item (milestone 5).
    var liveTextOn: Bool { state?.liveText ?? false }

    func setMode(_ mode: Mode) {
        guard mode != self.mode else { return }
        if mode == .phone { player.pause() }
        self.mode = mode
        followTranscript()
        updateComplication()
    }

    /// The Now Playing the complication last showed.
    @ObservationIgnored private var shown: WatchNowPlaying?
    @ObservationIgnored private var shownMode: Mode?

    /// The complication follows Now Playing, on real changes only (play, pause, a seek, another
    /// episode or chapter, the mode): its budget is small.
    private func updateComplication() {
        let playing = nowPlaying
        let same = shownMode == mode && shown?.key == playing?.key && shown?.isPlaying == playing?.isPlaying
            && shown?.chapter == playing?.chapter && shown?.rate == playing?.rate
            && (playing.map { now in shown.map { abs($0.position(at: now.sampledAt) - now.position) < 5 } ?? false } ?? (shown == nil))
        guard !same else { return }
        shown = playing
        shownMode = mode
        WatchStateStore.saveShown(playing)
        WidgetCenter.shared.reloadTimelines(ofKind: Self.complicationKind)
    }

    /// Plays an item that's on this watch, here (switching to Watch mode).
    func playOnWatch(_ item: WatchItem) async {
        guard let file = downloads.file(for: item) else { return }
        // The phone stops, so the two don't play at once.
        if state?.nowPlaying?.isPlaying == true { send(.togglePlay) }
        mode = .watch
        await player.play(item, file: file)
        followTranscript()
    }

    /// Listening goes to the phone: straight away when it's near (its answer drops what it has),
    /// otherwise queued with `transferUserInfo`, acknowledged later in its context.
    private func sendListening(_ stretches: [WatchListening]) {
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        let message = WatchMessages.userInfo(listening: stretches)
        // Each send has every pending stretch: an older copy still queued can go.
        for transfer in session.outstandingUserInfoTransfers where WatchMessages.listening(from: transfer.userInfo) != nil {
            transfer.cancel()
        }
        guard session.isReachable else {
            session.transferUserInfo(message)
            return
        }
        session.sendMessage(message) { @Sendable [weak self] reply in
            let applied = WatchMessages.acknowledged(from: reply)
            Task { @MainActor in if let applied { self?.player.log.acknowledge(applied) } }
        } errorHandler: { @Sendable _ in
            session.transferUserInfo(message)
        }
    }

    /// Sync Now: what's waiting goes now, and the list is checked again.
    func syncNow() async {
        player.log.flush()
        await downloads.reconcile()
    }

    /// The phone's list arrived: this watch's downloads follow it, and its places are taken
    /// where they're newer than this watch's.
    private func applyLibrary(_ library: WatchLibrary) async {
        player.log.acknowledge(library.acknowledged)
        for (key, place) in library.places {
            player.places.adopt(key, position: place.position, updatedAt: place.updatedAt)
        }
        await downloads.apply(library)
        // Removed from the list while loaded: stop. Still there: its details (a transcript) may be new.
        if let item = player.item {
            if let current = downloads.items.first(where: { $0.key == item.key }) { player.refresh(current) } else { player.stop() }
        }
        transcripts.prune(keeping: Set(downloads.items.map(\.key)))
        followTranscript()
        prefetchTranscripts()
    }

    /// Watch mode's buttons, on this watch's player. A mark waits for the phone, as an
    /// out-of-reach one does, at this watch's position.
    private func performHere(_ command: WatchCommand) {
        switch command {
        case .togglePlay:
            Task { await player.toggle() }
        case .skipBackward:
            Task { await player.skip(by: -player.skipBackward) }
        case .skipForward:
            Task { await player.skip(by: player.skipForward) }
        case .mark:
            guard let playing = player.nowPlaying else { return }
            let mark = WatchQueuedMark(playing, at: .now)
            WCSession.default.transferUserInfo(WatchMessages.userInfo(mark))
            WKInterfaceDevice.current().play(.success)
            confirmation = Confirmation(title: "Marked \(mark.position.watchClock)", detail: "Mine it later in Marks on your iPhone.")
        case let .markLine(key, position):
            guard let playing = player.nowPlaying, playing.key == key, let line = line(position) else { return }
            let mark = WatchQueuedMark(line: line, of: playing, at: .now)
            WCSession.default.transferUserInfo(WatchMessages.userInfo(mark))
            WKInterfaceDevice.current().play(.success)
            confirmation = Confirmation(title: "Marked \(mark.position.watchClock)", detail: "Mine it later in Marks on your iPhone.")
        case let .replayLine(key, position):
            guard player.item?.key == key, let line = line(position) else { return }
            Task { await player.replay(from: line.start, to: line.end) }
        case .endLookup:
            resumeAfterLookupHere()
        case let .seek(key, time):
            guard player.item?.key == key else { return }
            Task { await player.seek(to: time) }
        case let .setRate(rate):
            player.setRate(rate)
        default:
            break
        }
    }

    /// The lookup paused this watch's player: it plays again (unless played or paused since).
    private func resumeAfterLookupHere() {
        guard resumesAfterLookup else { return }
        resumesAfterLookup = false
        if !player.isPlaying { Task { await player.resume() } }
    }

    private func line(_ position: Int) -> WatchTranscript.Line? {
        transcript?.lines.first { $0.position == position }
    }

    @ObservationIgnored private var started = false

    /// Once, from the app or a background wake-up (whichever comes first).
    func start() {
        guard !started else { return }
        started = true
        downloads.requestAccess = { [weak self] in await self?.requestAccess() }
        player.onChange = { [weak self] in
            self?.coverForPlayer()
            self?.updateComplication()
        }
        downloads.onCover = { [weak self] in self?.coverForPlayer() }
        player.log.send = { [weak self] stretches in self?.sendListening(stretches) }
        #if DEBUG
        // Simulator checks: plays "<item>/<episode>" here once it's on the watch (SIMCTL_CHILD_KIKU_WATCH_PLAY).
        if let key = ProcessInfo.processInfo.environment["KIKU_WATCH_PLAY"] {
            Task { [weak self] in
                for _ in 0..<30 {
                    if let self, let item = downloads.items.first(where: { $0.key == key }), downloads.file(for: item) != nil {
                        await playOnWatch(item)
                        // KIKU_WATCH_PLAY_FOR=<seconds>: pauses after that long (listening goes to the phone).
                        if let seconds = ProcessInfo.processInfo.environment["KIKU_WATCH_PLAY_FOR"].flatMap(Double.init) {
                            try? await Task.sleep(for: .seconds(seconds))
                            player.pause()
                        }
                        return
                    }
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }
        #endif
        if let saved = WatchStateStore.load() { apply(saved, save: false) }
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    // MARK: Buttons

    func send(_ command: WatchCommand) {
        if mode == .watch {
            switch command {
            case .togglePlay, .skipBackward, .skipForward, .mark, .markLine, .replayLine, .endLookup, .seek, .setRate:
                return performHere(command)
            case .lookUp:
                // The phone looks it up (from its saved transcript); this watch pauses while you read.
                if player.isPlaying {
                    resumesAfterLookup = true
                    player.pause()
                }
            default:
                break
            }
        }
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
        send(.endLookup)
    }

    /// A token that lasts, from the phone (nil when it's out of reach).
    private func requestAccess() async -> WatchAccess? {
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else { return nil }
        let reply: WatchReply? = await withCheckedContinuation { continuation in
            session.sendMessage(WatchMessages.message(WatchCommand.freshAccess)) { @Sendable message in
                continuation.resume(returning: WatchMessages.reply(from: message))
            } errorHandler: { @Sendable _ in
                continuation.resume(returning: nil)
            }
        }
        return reply?.access
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
                if mode == .watch { resumeAfterLookupHere() }
                failed(reply.message ?? "No dictionary entry")
            }
        case .addCard:
            if reply.cardAdded == true {
                WKInterfaceDevice.current().play(.success)
                closeLookup()
                confirmation = Confirmation(symbol: "plus.circle.fill", title: "Card added", detail: reply.message ?? "")
            } else {
                failed(reply.message ?? "Couldn't add the card")
            }
        case let .transcriptPart(id, _):
            guard let part = reply.transcriptPart else {
                // The phone hasn't it (any more): not asked again this launch, unless it's playing.
                if fetching?.id == id {
                    fetching = nil
                    if nowPlaying?.transcript != id { unavailable.insert(id) }
                }
                prefetchTranscripts()
                return
            }
            guard part.id == fetching?.id else { return }
            if let whole = fetching?.add(part) {
                fetching = nil
                received(whole)
            } else if let next = part.next {
                send(.transcriptPart(id: part.id, from: next))
            }
        case .togglePlay, .skipBackward, .skipForward, .replayLine, .endLookup, .freshAccess, .seek, .setRate:
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
            // No dictionary here: a tapped word does nothing (marking its line instead surprised;
            // Mark Line is there for that).
            lookup = nil
            if mode == .watch { resumeAfterLookupHere() }
            return
        case .transcriptPart:
            // Asked again when the phone is back.
            fetching = nil
            return
        case .endLookup:
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
        if let playing = newState.nowPlaying {
            // The phone's skip intervals, for this watch's player too.
            player.skipBackward = playing.skipBackward
            player.skipForward = playing.skipForward
        }
        state = newState
        if let playing = newState.nowPlaying, let artwork = playing.artwork { downloads.keepCover(artwork, for: playing.itemId) }
        if save {
            WatchStateStore.save(newState)
            updateComplication()
        }
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
        try? transcripts.save(transcript, keeping: Set(downloads.items.map(\.key)))
        if nowPlaying?.transcript == transcript.id { self.transcript = transcript }
        prefetchTranscripts()
    }

    /// Live Text without the phone (milestone 5): each item's transcript, fetched one at a time
    /// while the phone is near, and kept as long as the item is here.
    private func prefetchTranscripts() {
        guard fetching == nil, WCSession.default.activationState == .activated, WCSession.default.isReachable,
              let id = downloads.items.compactMap(\.transcript).first(where: { !unavailable.contains($0) && transcripts.load(id: $0) == nil })
        else { return }
        fetching = WatchTranscriptAssembly(id: id)
        send(.transcriptPart(id: id, from: 0))
    }

    // MARK: WCSessionDelegate

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: (any Error)?) {
        let state = WatchMessages.state(from: session.receivedApplicationContext)
        let library = WatchMessages.library(from: session.receivedApplicationContext)
        let reachable = session.isReachable
        Task { @MainActor in
            self.isReachable = reachable
            if let state { self.apply(state) }
            if let library { await self.applyLibrary(library) } else { await self.downloads.reconcile() }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        let state = WatchMessages.state(from: applicationContext)
        let library = WatchMessages.library(from: applicationContext)
        Task { @MainActor in
            if let state { self.apply(state) }
            if let library { await self.applyLibrary(library) }
        }
    }

    /// The phone's list, sent as a complication transfer to wake Kiku here (the same list as
    /// the context, which may arrive later).
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        let library = WatchMessages.library(from: userInfo)
        Task { @MainActor in
            if let library { await self.applyLibrary(library) }
        }
    }

    /// Send Now's file: moved out of the inbox before this returns (WatchConnectivity deletes it).
    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        guard let key = WatchMessages.fileKey(from: file.metadata) else { return }
        let held = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        guard (try? FileManager.default.moveItem(at: file.fileURL, to: held)) != nil else { return }
        Task { @MainActor in await self.downloads.received(file: held, key: key) }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in
            self.isReachable = reachable
            guard reachable else { return }
            self.followTranscript()
            self.prefetchTranscripts()
            self.player.log.flush()
            // Waiting for the phone's token: it's near again.
            await self.downloads.reconcile()
        }
    }

}
