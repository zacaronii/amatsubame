#if os(iOS)
import AVFoundation
import AppCommon
import Core
import KikuWatchLink
import Lookup
import UIKit
import WatchConnectivity

/// Kiku's side of Apple Watch (docs/watch.md). The iPhone stays the brain: it keeps playing, and
/// the watch is a screen and a button. This sends what's playing whenever it changes (not every
/// second: the watch works the position out), and answers the watch: its buttons, Live Text's
/// transcript, lookups and cards.
final class WatchBridge: NSObject, WCSessionDelegate {
    private unowned let environment: KikuEnvironment
    /// What the watch was last told, so a state it can predict isn't sent again.
    private var sent: WatchState?
    /// Each item's small cover for the watch (nil while loading or when there's none).
    private var artwork: [String: Data?] = [:]
    private var started = false
    /// Kiku ▸ Settings ▸ Playback ▸ Live Text on Apple Watch. Off: no transcripts are sent.
    private(set) var liveText = false
    /// Each episode's transcript fingerprint, by key (so the database isn't read on every tick).
    private var fingerprints: [String: String] = [:]
    /// The transcript the watch is fetching in parts, built once.
    private var shared: WatchTranscript?
    /// The last word looked up from the watch, for its +.
    private var lastLookup: (command: WatchCommand, page: LookupResultPage)?
    /// Replay paused the episode: it plays again when the clip ends.
    private var resumesAfterClip = false
    /// A lookup from the watch paused the episode: it plays again when the watch closes it.
    private var resumesAfterLookup = false

    init(environment: KikuEnvironment) {
        self.environment = environment
    }

    func start() {
        guard !started, WCSession.isSupported() else { return }
        started = true
        liveText = ListenSettings.load(environment.common.database).watchLiveText
        WCSession.default.delegate = self
        WCSession.default.activate()
        follow()
    }

    func setLiveText(_ on: Bool) {
        liveText = on
        var settings = ListenSettings.load(environment.common.database)
        settings.watchLiveText = on
        try? settings.save(environment.common.database)
        send(currentState(), force: true)
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
        guard let playback = environment.playback else { return WatchState(nowPlaying: nil, liveText: liveText) }
        let entry = playback.entry
        let audio = playback.audio
        return WatchState(nowPlaying: WatchNowPlaying(
            itemId: entry.itemId, episodeId: entry.episode.id, title: entry.episode.title, subtitle: entry.showTitle,
            chapter: playback.currentChapter?.title, position: audio.currentTime,
            duration: audio.duration > 0 ? audio.duration : entry.duration, rate: Double(audio.rate),
            isPlaying: audio.isPlaying, sampledAt: .now, skipBackward: audio.skipIntervals.backward,
            skipForward: audio.skipIntervals.forward, artwork: cover(entry.itemId), transcript: transcriptId(playback)),
            liveText: liveText)
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
        guard state.liveText == sent.liveText else { return false }
        switch (sent.nowPlaying, state.nowPlaying) {
        case (nil, nil): return true
        case let (old?, new?): return old.predicts(new) && old.artwork == new.artwork
        default: return false
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

    // MARK: Live Text

    /// The playing episode's transcript id, with Live Text on and the transcript shown.
    private func transcriptId(_ playback: PlaybackModel) -> String? {
        guard liveText, !playback.sentences.isEmpty else { return nil }
        let key = playback.key
        // A transcript replaced by Kaku's newer one has new lines: read its fingerprint again.
        let cacheKey = "\(key)|\(playback.sentences.count)|\(playback.sentences.last?.text ?? "")"
        if fingerprints[cacheKey] == nil {
            fingerprints[cacheKey] = (try? environment.transcripts.transcript(key: key))?.fingerprint ?? "\(playback.sentences.count)"
        }
        return WatchTranscript.id(key: key, fingerprint: fingerprints[cacheKey]!)
    }

    private func watchTranscript(_ playback: PlaybackModel) -> WatchTranscript? {
        guard let id = transcriptId(playback), let fingerprint = id.split(separator: "#", maxSplits: 1).last else { return nil }
        return WatchTranscript(key: playback.key, fingerprint: String(fingerprint), lines: playback.sentences.map {
            WatchTranscript.Line(position: $0.position, start: $0.start, end: $0.end, text: TappableLine.sentence($0.text))
        })
    }

    /// Part of the playing episode's transcript, if it's still the one the watch asked for.
    private func transcriptPart(_ id: String, from: Int, of playback: PlaybackModel) -> WatchTranscriptPart? {
        if shared?.id != id { shared = watchTranscript(playback) }
        guard let shared, shared.id == id else { return nil }
        return shared.part(from: from)
    }

    // MARK: Commands

    private func perform(_ command: WatchCommand) async -> WatchReply {
        guard let playback = environment.playback else { return reply("Nothing is playing") }
        let audio = playback.audio
        switch command {
        case .togglePlay:
            // Played or paused by hand: closing the lookup leaves it be.
            resumesAfterLookup = false
            audio.toggle()
        case .skipBackward:
            audio.skip(by: -audio.skipIntervals.backward)
        case .skipForward:
            audio.skip(by: audio.skipIntervals.forward)
        case .mark:
            guard let mark = environment.mark(.watch) else { return reply("Nothing is playing") }
            chime()
            return WatchReply(message: "Marked \(mark.time.clockText)", markedAt: mark.time, state: currentState())
        case let .markLine(key, position):
            guard let line = line(key, position, in: playback) else { return reply("That episode isn't playing any more") }
            let entry = playback.entry
            // At the line's start, marked as chosen: Marks shows that line, not the one before.
            guard let mark = environment.mark(.watchLine, itemId: entry.itemId, episodeId: entry.episode.id, showTitle: entry.showTitle,
                                              episodeTitle: entry.episode.title, time: line.start) else { return reply("Couldn't mark it") }
            chime()
            return WatchReply(message: "Marked \(mark.time.clockText)", markedAt: mark.time, state: currentState())
        case let .replayLine(key, position):
            guard let line = line(key, position, in: playback) else { return reply("That episode isn't playing any more") }
            replay(line, in: playback)
        case let .lookUp(key, position, character):
            guard let line = line(key, position, in: playback) else { return reply("That episode isn't playing any more") }
            // As a tap in the transcript does: pause while you read it.
            if audio.isPlaying {
                resumesAfterLookup = true
                audio.pause()
            }
            let page = await lookUp(line, character: character)
            guard let first = page.results.first, let source = page.source else {
                resumeAfterLookup(playback)
                return reply("No dictionary entry")
            }
            lastLookup = (command, page)
            let start = LineLookup.characterIndex(utf16: source.utf16Offset, in: source.text)
            let end = LineLookup.characterIndex(utf16: source.utf16Offset + source.utf16Length, in: source.text)
            let lookup = WatchLookup(
                start: start, length: end - start, expression: first.expression, reading: first.reading,
                meaning: CompactDefinitionSummary.extract(first.glossaries, maximumItems: 1)?.items.first,
                frequency: first.frequencies.first?.values.first?.display, lookupCount: page.lookupCount,
                isMined: environment.common.lookup.mining?.isMined(first) ?? false)
            return WatchReply(lookup: lookup, state: currentState())
        case let .addCard(key, position, character):
            guard let line = line(key, position, in: playback) else { return reply("That episode isn't playing any more") }
            let page = lastLookup.flatMap { $0.command == .lookUp(key: key, line: position, character: character) ? $0.page : nil }
            let found = if let page { page } else { await lookUp(line, character: character) }
            guard let first = found.results.first else { return reply("No dictionary entry") }
            let mining = environment.common.mining
            do {
                _ = try await mining.mine(first, sentence: found.sentence ?? line.text, context: playback.miningContext(for: line))
                let deck = (try? mining.settingsStore.settings())?.deck
                return WatchReply(message: deck.map { "\(first.expression) · \($0)" } ?? first.expression, cardAdded: true, state: currentState())
            } catch {
                return reply("Set up Anki in Kiku's settings to add cards")
            }
        case .endLookup:
            resumeAfterLookup(playback)
        case let .transcriptPart(id, from):
            guard let part = transcriptPart(id, from: from, of: playback) else { return reply("That transcript isn't playing any more") }
            return WatchReply(transcriptPart: part, state: currentState())
        }
        return WatchReply(state: currentState())
    }

    private func resumeAfterLookup(_ playback: PlaybackModel) {
        guard resumesAfterLookup else { return }
        resumesAfterLookup = false
        if !playback.audio.isPlaying { playback.audio.play() }
    }

    private func reply(_ message: String) -> WatchReply {
        WatchReply(message: message, state: currentState())
    }

    private func line(_ key: String, _ position: Int, in playback: PlaybackModel) -> AudioSentence? {
        guard playback.key == key else { return nil }
        return playback.sentences.first { $0.position == position }
    }

    /// The same lookup a tap in the transcript makes (it's counted, and kept in history).
    private func lookUp(_ line: AudioSentence, character: Int) async -> LookupResultPage {
        let text = TappableLine.sentence(line.text)
        let offset = String(text.prefix(character)).utf16.count
        return await environment.common.lookup.lookup(text: text, utf16Offset: offset, showSource: true)
    }

    /// The line's clip on the phone (the transcript's clip path). The episode pauses for it and
    /// plays again after.
    private func replay(_ line: AudioSentence, in playback: PlaybackModel) {
        if playback.audio.isPlaying {
            resumesAfterClip = true
            playback.audio.pause()
        }
        playback.clip.stop()
        playback.playClip(line)
        resumeAfterClip(playback)
    }

    private func resumeAfterClip(_ playback: PlaybackModel) {
        let playing = withObservationTracking { playback.clip.isPlaying } onChange: { [weak self, weak playback] in
            Task { @MainActor in
                guard let self, let playback else { return }
                self.resumeAfterClip(playback)
            }
        }
        guard !playing, resumesAfterClip else { return }
        resumesAfterClip = false
        // Not if the episode was played or changed meanwhile.
        if environment.playback === playback, !playback.audio.isPlaying { playback.audio.play() }
    }

    /// A mark the watch made while the phone was out of reach: at the place the watch worked out.
    private func markQueued(_ queued: WatchQueuedMark) {
        environment.mark(queued.wholeLine == true ? .watchLine : .watch, itemId: queued.itemId, episodeId: queued.episodeId,
                         showTitle: queued.subtitle, episodeTitle: queued.title, time: queued.position)
    }

    /// As with AirPods: a chime you hear, but never out loud through the speaker.
    private func chime() {
        if Self.playsToHeadphones { MarkChime.play() }
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
            reply(WatchMessages.message(await self.perform(command)))
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let queued = WatchMessages.queuedMark(from: userInfo) else { return }
        Task { @MainActor in self.markQueued(queued) }
    }

}
#endif
