import AppCommon
import AudiobookshelfKit
import AVFoundation
import Core
import Foundation
import Lookup
import Observation

/// One episode playing: the audio, its transcript and which line is current, saving progress,
/// logging listening time, and looking up words (which pauses until the popup closes).
@MainActor @Observable
final class PlaybackModel: Identifiable, LineLookupHost {
    enum TranscriptState: Equatable {
        case loading
        case ready
        /// Kaku has it queued or running.
        case waiting(KakuJob?)
        case unavailable(String)
    }

    enum SleepTimer: Equatable {
        case minutes(Int, ends: Date)
        case endOfEpisode
        /// A book: when the chapter playing ends (its end, in seconds).
        case endOfChapter(end: Double)
    }

    let entry: EpisodeEntry
    let audio = AudioPlayer()
    let clip = ClipPlayer()
    let lookup: LineLookup
    private(set) var transcript = TranscriptState.loading
    private(set) var sentences: [AudioSentence] = []
    private(set) var currentIndex: Int?
    /// Auto-scroll to the current line; off while you scroll by hand (Back to Now turns it back on).
    var follows = true
    /// The transcript, or the artwork with the current line (the speech-bubble button), kept for
    /// every episode.
    private(set) var showsTranscript = true
    /// The line looked up, for the popup's sentence bar.
    private(set) var lookupSentence: AudioSentence?
    private(set) var sleepTimer: SleepTimer?
    /// The newest place is more than a minute behind where this phone was (listening on the
    /// watch or another app since): the player asks which, rather than jump back silently.
    private(set) var resumeChoice: ResumeChoice?

    struct ResumeChoice: Equatable {
        /// The newer place, and where it's from ("Apple Watch").
        var newer: Double
        var newerFrom: String
        /// This phone's own.
        var mine: Double
        var plays: Bool
    }

    var id: String { entry.id }
    var key: String { entry.id }

    @ObservationIgnored private unowned let environment: KikuEnvironment
    @ObservationIgnored private var resumesAfterLookup = false
    @ObservationIgnored private var lastSaved: Double = -100
    @ObservationIgnored private var lastTick: Double?
    @ObservationIgnored private var unlogged: Double = 0
    /// Download Once Started was asked about this episode (once, on its first real listening).
    @ObservationIgnored private var offeredDownload = false
    @ObservationIgnored private var transcriptTask: Task<Void, Never>?
    @ObservationIgnored private var againTask: Task<Void, Never>?
    /// The audio reached its end in this player.
    @ObservationIgnored private var playedToEnd = false
    /// When playback was last paused (for picking up from the line's start).
    @ObservationIgnored private var pausedAt: Date?
    /// `close()` has run: nothing still on its way may start the audio or a transcript loop.
    @ObservationIgnored private var closed = false
    /// What made the transcript showing and when (the More menu); nil until one is saved.
    private(set) var transcriptSource: AudioTranscriptInfo?
    /// Kaku was asked to transcribe this again; its new transcript replaces the one showing.
    private(set) var isTranscribingAgain = false
    private(set) var transcribeAgainProblem: String?
    @ObservationIgnored private var sleepTask: Task<Void, Never>?
    @ObservationIgnored private var lastRecovery: Date?
    /// Where the audio comes from (the download or the stream), clips and card media.
    @ObservationIgnored let episodeAudio: EpisodeAudio

    init(entry: EpisodeEntry, environment: KikuEnvironment) {
        self.entry = entry
        self.environment = environment
        episodeAudio = EpisodeAudio(entry: entry)
        lookup = LineLookup(service: environment.common.lookup)
        audio.onTick = { [weak self] time in self?.tick(time) }
        audio.onEnd = { [weak self] in self?.finished() }
        audio.onFailure = { [weak self] in self?.recoverStream() }
        audio.onPlayStateChange = { [weak self] playing in self?.playStateChanged(playing) }
        // AirPods: double press goes to the next line (as in Miru), triple press marks. A car's
        // steering-wheel buttons send the same commands, but skip there (CarPlay has a Mark button).
        audio.onNextTrack = { [weak self] in
            guard let self else { return }
            if Self.playsInCar { audio.skip(by: audio.skipIntervals.forward) } else { nextLine() }
        }
        audio.onPreviousTrack = { [weak self, weak environment] in
            guard let self else { return }
            if Self.playsInCar { return audio.skip(by: -audio.skipIntervals.backward) }
            if environment?.mark(.headphones) != nil { MarkChime.play() }
        }
        let settings = ListenSettings.load(environment.common.database)
        showsTranscript = settings.showsTranscript
        audio.rate = Float(settings.speed)
        audio.skipIntervals = (settings.skipBackward, settings.skipForward)
    }

    // MARK: Starting

    /// Loads the audio at the newer of the local and server positions (or `at`), then the transcript.
    func start(at time: Double? = nil, autoplay: Bool = true) async {
        let local = try? environment.listenProgress.progress(itemId: key)
        var position = time ?? LocalWatchProgress.resumePosition(
            local: local, server: entry.progress?.currentTime, serverDate: entry.progress?.updatedAt)
        if time == nil, entry.isFinished || (entry.duration > 0 && position > entry.duration - 5) { position = 0 }
        var autoplay = autoplay
        // Not in the car: the question is a dialog on the phone, and the car would stay silent.
        if time == nil, !Self.playsInCar, let choice = Self.resumeChoice(local: local, entry: entry, position: position, autoplay: autoplay,
                                                       watchPlayedAt: watchPlayedAt) {
            // Loaded at the newer place, paused until you choose.
            resumeChoice = choice
            autoplay = false
        }
        let problem = await episodeAudio.resolve(environment: environment)
        // Stopped (or another episode started) while the audio was being found.
        guard !closed else { return }
        if let problem {
            audio.pauseWithError(problem)
            return
        }
        guard let source = episodeAudio.source else { return }
        audio.load(url: source.url, headers: source.headers, start: position, title: entry.episode.title, show: entry.showTitle)
        lastSaved = position
        if autoplay { audio.play() }
        if let coverRequest = episodeAudio.coverRequest, let image = try? await CoverLoader.image(for: coverRequest, maxPixelSize: 600) {
            audio.setArtwork(image)
        }
        loadTranscript()
    }

    /// The phone's last place when it's more than a minute ahead of the newer one being resumed.
    static func resumeChoice(local: LocalWatchProgress?, entry: EpisodeEntry, position: Double, autoplay: Bool,
                             watchPlayedAt: Date?) -> ResumeChoice? {
        guard let local, let server = entry.progress, server.updatedAt > local.updatedAt, !server.isFinished,
              position == server.currentTime, local.position - position > 60,
              local.duration <= 0 || local.duration - local.position >= 30 else { return nil }
        let fromWatch = watchPlayedAt.map { abs($0.timeIntervalSince(server.updatedAt)) < 2 } ?? false
        return ResumeChoice(newer: position, newerFrom: fromWatch ? "Apple Watch" : "Audiobookshelf", mine: local.position, plays: autoplay)
    }

    /// Continue from the place chosen.
    func resume(at position: Double) {
        guard let choice = resumeChoice else { return }
        resumeChoice = nil
        if position != choice.newer { audio.seek(to: position) }
        if choice.plays { audio.play() }
    }

    private var watchPlayedAt: Date? {
        #if os(iOS)
        environment.watchLibrary.watchPlayedAt[key]
        #else
        nil
        #endif
    }

    // MARK: Transcript

    func loadTranscript() {
        guard !closed else { return }
        transcriptTask?.cancel()
        transcriptTask = Task { [weak self] in
            guard let self else { return }
            if let saved = try? environment.transcripts.sentences(key: key), !saved.isEmpty {
                try? environment.transcripts.touch(key: key, at: .now)
                show(saved)
                // Kaku may have split its lines again since (kaku.resplit): take the new ones, quietly.
                guard let kaku = environment.kakuClient(),
                      case .ready(let document)? = try? await kaku.transcript(itemId: entry.itemId, episodeId: entry.episode.id),
                      !Task.isCancelled,
                      // …or made it again, or this copy is from before its source was kept.
                      document.sentences.map(\.text) != saved.map(\.text) || Self.isNewer(document, than: transcriptSource),
                      let fresh = try? environment.saveTranscript(document, entry: entry, played: true) else { return }
                show(fresh)
                return
            }
            guard let kaku = environment.kakuClient() else {
                transcript = .unavailable("Set up Kaku in Settings to see transcripts.")
                return
            }
            var asked = false
            while !Task.isCancelled {
                do {
                    switch try await kaku.transcript(itemId: entry.itemId, episodeId: entry.episode.id) {
                    case .ready(let document):
                        let sentences = try environment.saveTranscript(document, entry: entry, played: true)
                        environment.library.setStatus(.done, for: key)
                        show(sentences)
                        return
                    case .pending(let job):
                        if job.state == .failed {
                            transcript = .unavailable("Kaku couldn't transcribe this episode. \(job.error ?? "")")
                            return
                        }
                        transcript = .waiting(job)
                        environment.library.setStatus(job.state == .running ? .running : .queued, for: key)
                        if !asked, job.position.map({ $0 > 0 }) ?? false {
                            // Playing it now: ask for it first (Kaku's "now" priority).
                            asked = true
                            if let next = try await kaku.requestJob(itemId: entry.itemId, episodeId: entry.episode.id) { transcript = .waiting(next) }
                        }
                    case .missing:
                        guard !asked else { break }
                        asked = true
                        let job = try await kaku.requestJob(itemId: entry.itemId, episodeId: entry.episode.id)
                        transcript = .waiting(job)
                        environment.library.setStatus(.queued, for: key)
                        if job == nil { continue }
                    }
                } catch let error {
                    if error.isCancellation { return }
                    if sentences.isEmpty { transcript = .unavailable("Couldn't reach Kaku. \(error.localizedDescription)") }
                }
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    /// After a network change: the stream again if it stopped, and Kaku at once when the
    /// transcript isn't showing yet (the loop above would otherwise wait out its pause or a
    /// request stuck on the old network).
    func retryAfterReconnect() {
        if audio.failure != nil {
            lastRecovery = nil
            recoverStream()
        }
        switch transcript {
        case .waiting, .unavailable: loadTranscript()
        case .loading, .ready: break
        }
    }

    /// A stream that stopped (its hour-long Audiobookshelf sign-in ran out, or the network
    /// dropped) loads again where it was, with a renewed sign-in. At most once a minute, so a
    /// server that's down doesn't loop.
    private func recoverStream() {
        guard lastRecovery.map({ Date.now.timeIntervalSince($0) > 60 }) ?? true else { return }
        lastRecovery = .now
        Task {
            guard let source = await episodeAudio.renewStream(environment: environment) else { return }
            audio.reload(url: source.url, headers: source.headers)
        }
    }

    /// Whether Kaku's transcript is another one than the saved copy (made at another time).
    static func isNewer(_ document: KakuTranscript, than saved: AudioTranscriptInfo?) -> Bool {
        guard let created = document.source.created else { return false }
        guard let known = saved?.transcribedAt else { return true }
        return abs(created.timeIntervalSince(known)) > 1
    }

    /// "large-v3 · Kaku 1.5.0 · 5 Nov 2026": what made the transcript, for the More menu.
    static func sourceText(_ info: AudioTranscriptInfo) -> String {
        let parts = [info.model, info.kakuVersion.map { "Kaku \($0)" },
                     (info.transcribedAt ?? info.savedAt).formatted(date: .abbreviated, time: .omitted)]
        let text = parts.compactMap(\.self).joined(separator: " · ")
        // A copy from before the model was kept has only its date.
        return info.model == nil && info.kakuVersion == nil ? "Saved \(text)" : text
    }

    /// Asks Kaku to transcribe this episode again (Kaku 1.6), first in its queue, and shows the
    /// new transcript when it's made. The one showing stays until then.
    func transcribeAgain() {
        guard !isTranscribingAgain else { return }
        guard let kaku = environment.kakuClient() else {
            transcribeAgainProblem = "Set up Kaku in Settings first."
            return
        }
        let before = transcriptSource
        let asked = Date.now
        isTranscribingAgain = true
        transcribeAgainProblem = nil
        againTask = Task { [weak self] in
            guard let self else { return }
            defer { isTranscribingAgain = false }
            do {
                guard try await kaku.requestJob(itemId: entry.itemId, episodeId: entry.episode.id, force: true) != nil else {
                    // An older Kaku ignores `force` and answers that the transcript is current.
                    transcribeAgainProblem = "Kaku needs to be 1.6 or newer to transcribe again."
                    return
                }
            } catch {
                if !error.isCancellation { transcribeAgainProblem = "Couldn't reach Kaku. \(error.localizedDescription)" }
                return
            }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled, case .ready(let document)? = try? await kaku.transcript(itemId: entry.itemId, episodeId: entry.episode.id),
                      before?.transcribedAt != nil ? Self.isNewer(document, than: before)
                        : (document.source.created ?? .distantPast) > asked.addingTimeInterval(-120),
                      let fresh = try? environment.saveTranscript(document, entry: entry, played: true) else { continue }
                show(fresh)
                return
            }
        }
    }

    private func show(_ sentences: [AudioSentence]) {
        self.sentences = sentences
        transcriptSource = try? environment.transcripts.transcript(key: key)
        currentIndex = TranscriptFollow.index(at: audio.currentTime, in: sentences)
        // From a little before the line playing, so the lines on screen are marked first.
        let lines = sentences.map { TappableLine.sentence($0.text) }
        let from = max(0, min((currentIndex ?? 0) - 5, lines.count))
        environment.common.wordMarks.prepare(Array(lines[from...] + lines[..<from]))
        transcript = .ready
    }

    // MARK: Controls

    func previousLine() {
        guard !sentences.isEmpty else { return audio.skip(by: -audio.skipIntervals.backward) }
        audio.seek(to: TranscriptFollow.previousTarget(from: audio.currentTime, in: sentences))
        follows = true
    }

    /// The audio is going to a car (CarPlay, wired or wireless).
    static var playsInCar: Bool {
        #if os(iOS)
        AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.portType == .carAudio }
        #else
        false
        #endif
    }

    func nextLine() {
        guard !sentences.isEmpty else { return audio.skip(by: audio.skipIntervals.forward) }
        if let target = TranscriptFollow.nextTarget(from: audio.currentTime, in: sentences) { audio.seek(to: target) }
        follows = true
    }

    // MARK: Chapters (books)

    var currentChapter: AudiobookshelfChapter? { entry.chapter(at: audio.currentTime) }

    func play(chapter: AudiobookshelfChapter) {
        audio.seek(to: chapter.start)
        follows = true
        if !audio.isPlaying { audio.play() }
    }

    /// Like the line buttons: back to this chapter's start once you're a few seconds in, else the one before.
    func previousChapter() {
        let chapters = entry.chapters
        guard let current = currentChapter, let index = chapters.firstIndex(of: current) else { return }
        let target = audio.currentTime - current.start > 3 || index == 0 ? current : chapters[index - 1]
        play(chapter: target)
    }

    func nextChapter() {
        let chapters = entry.chapters
        guard let current = currentChapter, let index = chapters.firstIndex(of: current), index + 1 < chapters.count else { return }
        play(chapter: chapters[index + 1])
    }

    func play(from sentence: AudioSentence) {
        audio.seek(to: sentence.start)
        follows = true
        if !audio.isPlaying { audio.play() }
    }

    func setShowsTranscript(_ shows: Bool) {
        showsTranscript = shows
        // Back on: at the line playing.
        if shows { follows = true }
        var settings = ListenSettings.load(environment.common.database)
        settings.showsTranscript = shows
        try? settings.save(environment.common.database)
    }

    func setSpeed(_ speed: Double) {
        audio.rate = Float(speed)
        var settings = ListenSettings.load(environment.common.database)
        settings.speed = speed
        try? settings.save(environment.common.database)
    }

    func setSleepTimer(minutes: Int?) {
        sleepTask?.cancel()
        guard let minutes else { sleepTimer = nil; return }
        let ends = Date.now.addingTimeInterval(Double(minutes) * 60)
        sleepTimer = .minutes(minutes, ends: ends)
        sleepTask = Task { [weak self] in
            try? await Task.sleep(until: .now + .seconds(Double(minutes) * 60))
            guard !Task.isCancelled else { return }
            self?.audio.pause()
            self?.sleepTimer = nil
        }
    }

    func sleepAtEndOfEpisode() {
        sleepTask?.cancel()
        sleepTimer = .endOfEpisode
    }

    /// Stops at the end of the chapter playing now (books with chapters).
    func sleepAtEndOfChapter() {
        guard let chapter = currentChapter else { return }
        sleepTask?.cancel()
        sleepTimer = .endOfChapter(end: chapter.end)
    }

    /// Saves the place and stops (the player was closed for good).
    func close() {
        closed = true
        saveProgress(force: true)
        flushListening()
        environment.sessions.send()
        transcriptTask?.cancel()
        againTask?.cancel()
        sleepTask?.cancel()
        clip.stop()
        audio.stop()
        episodeAudio.discard()
    }

    // MARK: Lookup

    func tap(_ sentence: AudioSentence, characterIndex: Int) {
        if audio.isPlaying {
            resumesAfterLookup = true
            audio.pause()
        }
        lookupSentence = sentence
        lookup.lookUp(sentence.text, characterIndex: characterIndex, key: String(sentence.position), context: miningContext(for: sentence))
    }

    var resumesOnClose: Bool { resumesAfterLookup }

    func popupClosed() {
        lookup.close()
        clip.stop()
        lookupSentence = nil
        if resumesAfterLookup {
            resumesAfterLookup = false
            audio.play()
        }
    }

    func playClip(_ sentence: AudioSentence) {
        episodeAudio.playClip(clip, from: sentence.start - AudioMiningContext.leadIn, to: sentence.end + AudioMiningContext.tail)
    }

    func miningContext(for sentence: AudioSentence) -> any MiningContext {
        episodeAudio.miningContext(for: sentence)
    }

    // MARK: Progress and listening time

    private func tick(_ time: Double) {
        let index = TranscriptFollow.index(at: time, in: sentences)
        if index != currentIndex { currentIndex = index }
        if audio.isPlaying, let lastTick {
            let step = time - lastTick
            // Only real playback counts (not seeks), at any speed.
            if step > 0, step < 1.5 { unlogged += 0.25 }
        }
        lastTick = time
        if unlogged >= 10 { flushListening() }
        if abs(time - lastSaved) >= 15 { saveProgress() }
        if case .minutes(_, let ends) = sleepTimer, ends <= .now { sleepTimer = nil }
        // The chapter's last moment: stop there, at the start of the next one.
        if case .endOfChapter(let end) = sleepTimer, audio.isPlaying, time >= end - 0.3 {
            sleepTimer = nil
            audio.pause()
        }
    }

    private func playStateChanged(_ playing: Bool) {
        if playing {
            // From the start of the line the pause cut off.
            if let pausedAt, let target = TranscriptFollow.resumeTarget(at: audio.currentTime, in: sentences,
                                                                        pausedFor: Date.now.timeIntervalSince(pausedAt)) {
                audio.seek(to: target)
            }
            pausedAt = nil
            // Pressing play yourself while the popup is open: don't resume again when it closes.
            resumesAfterLookup = false
            // Started some other way (AirPods, the Lock Screen): the place loaded is the answer.
            resumeChoice = nil
        } else {
            pausedAt = .now
            saveProgress(force: true)
            flushListening()
            environment.sessions.send()
        }
        lastTick = nil
    }

    private func finished() {
        // The sleep timer's End of Episode means stop here.
        let stopsHere = sleepTimer == .endOfEpisode
        if stopsHere { sleepTimer = nil }
        pausedAt = nil
        saveProgress(force: true, finished: true)
        flushListening()
        environment.sessions.send()
        // Download ahead moves on past a finished episode.
        environment.autoDownloads.schedule()
        if !stopsHere { environment.playNext(after: entry) }
    }

    private func flushListening() {
        guard unlogged > 0 else { return }
        if !offeredDownload {
            offeredDownload = true
            environment.autoDownloads.startedPlaying(entry)
        }
        let subject = ActivitySubject(kind: .listening, seriesKey: entry.itemId, seriesTitle: entry.collectionTitle, itemKey: key)
        try? environment.common.activity.record(subject, seconds: unlogged)
        environment.sessions.listened(unlogged, item: ListenedItem(itemId: entry.itemId, episodeId: entry.episode.id,
                                                                   title: entry.episode.title, duration: audio.duration > 0 ? audio.duration : entry.duration),
                                      position: audio.currentTime)
        unlogged = 0
    }

    func saveProgress(force: Bool = false, finished: Bool = false) {
        let time = finished ? audio.duration : audio.currentTime
        let duration = audio.duration > 0 ? audio.duration : entry.duration
        guard duration > 0, force || abs(time - lastSaved) >= 15 else { return }
        lastSaved = time
        let now = Date.now
        if finished { playedToEnd = true }
        // Still finished when the place is saved again at the end (closing the player, the next
        // episode starting): it used to go back to unfinished at 100%.
        let isFinished = finished || ((playedToEnd || entry.isFinished) && time >= duration - 5)
        try? environment.listenProgress.save(LocalWatchProgress(itemId: key, seriesId: entry.itemId, position: time, duration: duration, updatedAt: now))
        let payload = AudiobookshelfProgressPayload(itemId: entry.itemId, episodeId: entry.episode.id, currentTime: time,
                                                    duration: duration, isFinished: isFinished, reportedAt: now)
        try? environment.common.outbox.enqueue(payload, kind: .audiobookshelfProgress, coalesceKey: payload.coalesceKey)
        environment.common.syncNow(retryWaiting: false)
        environment.library.update(progress: AudiobookshelfProgress(
            libraryItemId: entry.itemId, episodeId: entry.episode.id, duration: duration, progress: time / duration,
            currentTime: time, isFinished: isFinished, lastUpdate: now.timeIntervalSince1970 * 1000))
    }
}
