import AppCommon
import AudiobookshelfKit
import Core
import Foundation
import Lookup
import Observation
import Readers

/// Reading along with a paired audiobook: plays it, highlights the spoken sentence and keeps it
/// on screen, pauses for lookups, gives cards the sentence's audio, and moves Audiobookshelf's
/// place (the reader moves Kavita's as its pages turn).
@MainActor @Observable
final class ReadAlongModel: BookReadAlongHost {
    let pair: ReadAlongPair
    let cues: ReadAlongCues
    let audio = AudioPlayer()
    /// The looked-up sentence on its own (the popup's clip row), without moving the main audio.
    let clip = ClipPlayer()
    private(set) var currentIndex: Int?
    /// Keep the spoken sentence on screen; turning pages by hand turns it off.
    private(set) var follows = true
    private(set) var isLoaded = false
    private(set) var problem: String?
    /// The sentence a word was last looked up in: "Play from here".
    private(set) var tappedIndex: Int?
    /// Off is plain reading: no audio, highlight or Follow Audio (the reader's headphones
    /// button, remembered per volume).
    private(set) var isOn: Bool

    @ObservationIgnored private weak var reader: BookReaderModel?
    @ObservationIgnored private unowned let environment: AppEnvironment
    @ObservationIgnored private var resumesAfterLookup = false
    @ObservationIgnored private var lastSaved: Double = -100
    @ObservationIgnored private var localFile: URL?
    @ObservationIgnored private var source: (url: URL, headers: [String: String])?
    /// The stream asked for again with a renewed sign-in (nil for a download).
    @ObservationIgnored private var renewStream: (() async -> (url: URL, headers: [String: String])?)?
    @ObservationIgnored private var lastRecovery: Date?
    @ObservationIgnored private var duration: Double = 0
    /// Turned on from the switch: listen from the page on screen, not where listening stopped.
    @ObservationIgnored private var startsFromPage = false

    init(pair: ReadAlongPair, cues: ReadAlongCues, reader: BookReaderModel, environment: AppEnvironment, isOn: Bool) {
        self.pair = pair
        self.isOn = isOn
        self.cues = cues
        self.reader = reader
        self.environment = environment
        audio.onTick = { [weak self] time in self?.tick(time) }
        audio.onPlayStateChange = { [weak self] playing in self?.playStateChanged(playing) }
        audio.onEnd = { [weak self] in self?.saveProgress(force: true, finished: true) }
        audio.onFailure = { [weak self] in self?.recoverStream() }
        let settings = ListenSettings.load(environment.database)
        audio.skipIntervals = (settings.skipBackward, settings.skipForward)
    }

    var key: String { pair.itemId }
    var currentCue: ReadAlongCue? { currentIndex.map { cues.cues[$0] } }

    // MARK: Starting

    /// Loads the audio (the download, else the stream) at the right place: a time from Kiku's
    /// link, else where Audiobookshelf was if it moved after this book was last read (listening
    /// in Kiku), else this page.
    func start() async {
        guard isOn, !isLoaded, let reader else { return }
        let client = environment.audiobookshelfClient()
        localFile = ReadAlongAudio.localFile(itemId: pair.itemId)
        var source: (url: URL, headers: [String: String])?
        if let localFile {
            source = (localFile, [:])
        } else if let client, let item = try? await client.item(id: pair.itemId),
                  let whole = AudiobookshelfEpisode.wholeBook(item), let ino = whole.audioFile?.ino,
                  let request = try? await client.audioRequest(itemId: pair.itemId, ino: ino), let url = request.url {
            source = (url, request.allHTTPHeaderFields ?? [:])
            duration = whole.length ?? 0
            let itemId = pair.itemId
            renewStream = {
                guard let request = try? await client.audioRequest(itemId: itemId, ino: ino), let url = request.url else { return nil }
                return (url, request.allHTTPHeaderFields ?? [:])
            }
        }
        guard let source else {
            problem = "Sign in to Audiobookshelf in Settings, or download the audio, to read along."
            return
        }
        let local = try? environment.listenProgress.progress(itemId: key)
        let server = try? await client?.progress(itemId: pair.itemId, episodeId: "")
        let listened = LocalWatchProgress.resumePosition(local: local, server: server?.currentTime, serverDate: server?.updatedAt)
        let listenedAt = [local?.updatedAt, server?.updatedAt].compactMap(\.self).max()
        let readAt = (try? environment.readingProgress.progress(chapterId: pair.chapterId))?.updatedAt
        var position: Double
        if let linked = environment.linkedListening.removeValue(forKey: key), let index = cues.index(at: linked) {
            // Opened from Kiku's Read in Yomu: its time wins.
            position = linked
            reader.open(at: cues.cues[index])
        } else if !startsFromPage, let listenedAt, listened > 0, readAt.map({ listenedAt > $0 }) ?? true, let index = cues.index(at: listened) {
            // Listening moved last: open the book at that sentence.
            position = listened
            reader.open(at: cues.cues[index])
        } else {
            // From this page (switched on here, or reading moved last): its first matched sentence,
            // else the last one before it (pages back, where matching last worked). The page stays
            // put; Follow Audio goes there.
            startsFromPage = false
            follows = false
            let place = await reader.firstVisiblePlace()
            position = cues.startIndex(section: place.section, run: place.run, offset: place.offset, nextPage: place.next)
                .map { cues.cues[$0].start } ?? listened
        }
        if position < 0 { position = 0 }
        self.source = source
        audio.load(url: source.url, headers: source.headers, start: position, title: pair.bookTitle, show: "Read-along")
        lastSaved = position
        isLoaded = true
        tick(position)
    }

    /// A stream that stopped (its hour-long Audiobookshelf sign-in ran out, or the network
    /// dropped) loads again where it was, at most once a minute.
    private func recoverStream() {
        guard let renewStream, lastRecovery.map({ Date.now.timeIntervalSince($0) > 60 }) ?? true else { return }
        lastRecovery = .now
        Task {
            guard let renewed = await renewStream() else { return }
            source = renewed
            audio.reload(url: renewed.url, headers: renewed.headers)
        }
    }

    // MARK: Controls

    /// Turns reading along on or off for this volume. On, the bar appears and starts listening
    /// from this page; off, the audio stops and its place is saved.
    func setOn(_ on: Bool) {
        guard on != isOn else { return }
        isOn = on
        try? environment.readAlongPairs.setReadsAlong(chapterId: pair.chapterId, on)
        if on { startsFromPage = true }
        if !on {
            close()
            (follows, tappedIndex, currentIndex, problem) = (true, nil, nil, nil)
        }
        reader?.showMessage(on ? "Reading along" : "Read-along off")
    }

    func toggle() {
        if !isLoaded { return }
        if !audio.isPlaying { follow() }
        audio.toggle()
    }

    func previousSentence() {
        guard let index = currentIndex ?? cues.index(at: audio.currentTime) else { return }
        // Like the line buttons in Kiku: back to this sentence's start, or the one before.
        let target = audio.currentTime - cues.cues[index].start > 2 || index == 0 ? index : index - 1
        seek(to: target)
    }

    func nextSentence() {
        let next = (currentIndex ?? -1) + 1
        if next < cues.cues.count { seek(to: next) }
    }

    func follow() {
        follows = true
        if let cue = currentCue { reader?.showReadAlong(cue, follow: true) }
    }

    /// Plays from the sentence a word was looked up in.
    func playFromTapped() {
        guard let tappedIndex else { return }
        seek(to: tappedIndex)
        self.tappedIndex = nil
        if !audio.isPlaying { audio.play() }
    }

    func setSpeed(_ speed: Double) {
        audio.rate = Float(speed)
    }

    private func seek(to index: Int) {
        follows = true
        audio.seek(to: cues.cues[index].start)
        tick(cues.cues[index].start)
    }

    // MARK: Following

    private func tick(_ time: Double) {
        // A late tick from the stopped player mustn't bring the highlight back.
        guard isOn, isLoaded else { return }
        let index = cues.index(at: time)
        if index != currentIndex {
            currentIndex = index
            reader?.showReadAlong(index.map { cues.cues[$0] }, follow: follows)
        }
        // While playing: the player's first tick (0, before it seeks) isn't listening.
        if audio.isPlaying, abs(time - lastSaved) >= 15 { saveProgress() }
    }

    private func playStateChanged(_ playing: Bool) {
        ScreenAwake.set(playing)
        if playing {
            resumesAfterLookup = false
            tappedIndex = nil
            if !follows { follow() }
        } else {
            // Only when it moved: stopping unplayed audio mustn't look like listening since reading.
            saveProgress(force: abs(audio.currentTime - lastSaved) > 1)
        }
    }

    // MARK: BookReadAlongHost

    func lookupOpened(section: Int, run: Int, offset: Int) {
        guard isOn else { return }
        tappedIndex = cues.index(section: section, run: run, offset: offset)
        if audio.isPlaying {
            resumesAfterLookup = true
            audio.pause()
        }
    }

    /// The sentence a word was looked up in, while reading along: what the card's audio is.
    var tappedCue: ReadAlongCue? { isOn ? tappedIndex.map { cues.cues[$0] } : nil }

    /// Plays (or stops) the looked-up sentence, with the same lead-in and tail as the card's.
    func playTappedClip() {
        if clip.isPlaying { return clip.stop() }
        guard let cue = tappedCue, let source else { return }
        clip.play(url: source.url, headers: source.headers, from: max(cue.start - AudioClips.leadIn, 0), to: cue.end + AudioClips.tail)
    }

    func lookupClosed() {
        clip.stop()
        if resumesAfterLookup {
            resumesAfterLookup = false
            audio.play()
        }
    }

    /// Paging away from the spoken sentence shows Follow Audio, playing or paused; playing
    /// again goes back to it.
    func userTurnedPage() {
        follows = false
    }

    func sentenceAudio(section: Int, run: Int, offset: Int) -> (@concurrent @Sendable () async -> SentenceAudio?)? {
        guard let index = cues.index(section: section, run: run, offset: offset) else { return nil }
        let cue = cues.cues[index]
        if let localFile {
            return { await AudioClips.sentenceAudio(file: localFile, start: cue.start, end: cue.end) }
        }
        guard let kaku = environment.kakuClient() else { return nil }
        let itemId = pair.itemId
        return {
            guard let data = try? await kaku.clip(itemId: itemId, episodeId: "", start: max(cue.start - AudioClips.leadIn, 0),
                                                  end: cue.end + AudioClips.tail) else { return nil }
            return SentenceAudio(data: data, fileExtension: "m4a")
        }
    }

    // MARK: Progress

    /// Audiobookshelf's place, through the outbox (and kept locally for resuming offline).
    func saveProgress(force: Bool = false, finished: Bool = false) {
        guard isLoaded else { return }
        let time = finished ? audio.duration : audio.currentTime
        let length = audio.duration > 0 ? audio.duration : duration
        guard length > 0, force || abs(time - lastSaved) >= 15 else { return }
        lastSaved = time
        let now = Date.now
        try? environment.listenProgress.save(LocalWatchProgress(itemId: key, seriesId: pair.itemId, position: time, duration: length, updatedAt: now))
        let payload = AudiobookshelfProgressPayload(itemId: pair.itemId, episodeId: "", currentTime: time, duration: length,
                                                    isFinished: finished, reportedAt: now)
        try? environment.outbox.enqueue(payload, kind: .audiobookshelfProgress, coalesceKey: payload.coalesceKey)
        environment.syncNow()
    }

    func close() {
        // Only when the place moved, so an unchanged one doesn't look newer than reading since.
        saveProgress(force: abs(audio.currentTime - lastSaved) > 1)
        audio.stop()
        isLoaded = false
        ScreenAwake.set(false)
        reader?.showReadAlong(nil, follow: false)
    }
}

/// Yomu's own copies of paired audiobooks, for reading along offline.
enum ReadAlongAudio {
    static var folder: URL { URL.applicationSupportDirectory.appending(path: "ReadAlongAudio") }

    static func localFile(itemId: String) -> URL? {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.first { $0.deletingPathExtension().lastPathComponent == itemId && $0.pathExtension != "part" }
    }
}
