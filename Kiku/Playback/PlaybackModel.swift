import AppCommon
import AudiobookshelfKit
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

    var id: String { entry.id }
    var key: String { entry.id }

    @ObservationIgnored private unowned let environment: KikuEnvironment
    @ObservationIgnored private var resumesAfterLookup = false
    @ObservationIgnored private var lastSaved: Double = -100
    @ObservationIgnored private var lastTick: Double?
    @ObservationIgnored private var unlogged: Double = 0
    @ObservationIgnored private var transcriptTask: Task<Void, Never>?
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
        // AirPods: double press goes to the next line (as in Miru), triple press marks.
        audio.onNextTrack = { [weak self] in self?.nextLine() }
        audio.onPreviousTrack = { [weak environment] in
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
        if let problem = await episodeAudio.resolve(environment: environment) {
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

    // MARK: Transcript

    func loadTranscript() {
        transcriptTask?.cancel()
        transcriptTask = Task { [weak self] in
            guard let self else { return }
            if let saved = try? environment.transcripts.sentences(key: key), !saved.isEmpty {
                try? environment.transcripts.touch(key: key, at: .now)
                show(saved)
                // Kaku may have split its lines again since (kaku.resplit): take the new ones, quietly.
                guard let kaku = environment.kakuClient(),
                      case .ready(let document)? = try? await kaku.transcript(itemId: entry.itemId, episodeId: entry.episode.id),
                      !Task.isCancelled, document.sentences.map(\.text) != saved.map(\.text),
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

    private func show(_ sentences: [AudioSentence]) {
        self.sentences = sentences
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

    /// Saves the place and stops (the player was closed for good).
    func close() {
        saveProgress(force: true)
        flushListening()
        transcriptTask?.cancel()
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
    }

    private func playStateChanged(_ playing: Bool) {
        if playing {
            // Pressing play yourself while the popup is open: don't resume again when it closes.
            resumesAfterLookup = false
        } else {
            saveProgress(force: true)
            flushListening()
        }
        lastTick = nil
    }

    private func finished() {
        if sleepTimer == .endOfEpisode { sleepTimer = nil }
        saveProgress(force: true, finished: true)
        flushListening()
    }

    private func flushListening() {
        guard unlogged > 0 else { return }
        let subject = ActivitySubject(kind: .listening, seriesKey: entry.itemId, seriesTitle: entry.collectionTitle, itemKey: key)
        try? environment.common.activity.record(subject, seconds: unlogged)
        unlogged = 0
    }

    func saveProgress(force: Bool = false, finished: Bool = false) {
        let time = finished ? audio.duration : audio.currentTime
        let duration = audio.duration > 0 ? audio.duration : entry.duration
        guard duration > 0, force || abs(time - lastSaved) >= 15 else { return }
        lastSaved = time
        let now = Date.now
        let isFinished = finished || (entry.isFinished && time >= duration - 5)
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
