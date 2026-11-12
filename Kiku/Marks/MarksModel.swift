import AppCommon
import AudiobookshelfKit
import Core
import Foundation
import Lookup
import Observation

/// The Marks tab's state: marks grouped by episode, each episode's saved lines, clips, and
/// looking up and mining from a mark (which records the word on it).
@MainActor @Observable
final class MarksModel: LineLookupHost {
    struct Group: Identifiable {
        var key: String
        var marks: [AudioMark]
        var id: String { key }
        var first: AudioMark { marks[0] }
    }

    private(set) var marks: [AudioMark] = []
    /// Saved transcript lines by episode key (empty until Kaku has one).
    private(set) var sentences: [String: [AudioSentence]] = [:]
    /// Episodes Kaku is still transcribing.
    private(set) var transcribing: Set<String> = []
    /// The mark whose 15 seconds are playing.
    private(set) var playingMark: Int64?
    private(set) var lookupSentence: AudioSentence?
    private(set) var problem: String?
    let clip = ClipPlayer()
    let lookup: LineLookup

    @ObservationIgnored private unowned let environment: KikuEnvironment
    @ObservationIgnored private var audios: [String: EpisodeAudio] = [:]
    @ObservationIgnored private var asked: Set<String> = []
    @ObservationIgnored private var resumesAfterLookup = false

    /// How much of the episode a mark's clip plays: the 15 seconds before it.
    static let clipLength = 15.0

    init(environment: KikuEnvironment) {
        self.environment = environment
        lookup = LineLookup(service: environment.common.lookup)
    }

    var toMine: Int { marks.count { !$0.isMined } }

    /// Episodes with their marks, the most recently marked first (episodes and marks alike).
    var groups: [Group] {
        var order: [String] = []
        var byKey: [String: [AudioMark]] = [:]
        for mark in marks {
            if byKey[mark.key] == nil { order.append(mark.key) }
            byKey[mark.key, default: []].append(mark)
        }
        return order.map { Group(key: $0, marks: byKey[$0]!) }
    }

    /// The lines under a mark, and which one it's likely about.
    func window(for mark: AudioMark) -> (lines: ArraySlice<AudioSentence>, marked: Int)? {
        // Lock Screen, AirPods and Shortcut marks come a moment late; the player's button doesn't.
        TranscriptFollow.markWindow(at: mark.time, in: sentences[mark.key] ?? [], guessesEarlier: mark.source != .player)
    }

    /// Marks whose lines contain `query` (Marks search's "In your marks").
    func matching(_ query: String) -> [AudioMark] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        return marks.filter { mark in window(for: mark)?.lines.contains { $0.text.localizedCaseInsensitiveContains(query) } ?? false }
    }

    // MARK: Loading

    func observe() async {
        do {
            for try await marks in environment.marks.observe() {
                self.marks = marks
                loadLines()
                await fetchTranscripts()
            }
        } catch {}
    }

    /// Pull to refresh: asks Kaku again for episodes still being transcribed.
    func refresh() async {
        asked.subtract(transcribing)
        await fetchTranscripts()
    }

    /// Back on the tab: the saved lines again, in case the player replaced a transcript
    /// with Kaku's newer one.
    func reloadLines() {
        for key in sentences.keys {
            let saved = (try? environment.transcripts.sentences(key: key)) ?? []
            if !saved.isEmpty, saved.map(\.text) != sentences[key]?.map(\.text) {
                sentences[key] = saved
                environment.common.wordMarks.prepare(saved.map { TappableLine.sentence($0.text) })
            }
        }
    }

    private func loadLines() {
        for key in Set(marks.map(\.key)) where sentences[key]?.isEmpty ?? true {
            let saved = (try? environment.transcripts.sentences(key: key)) ?? []
            sentences[key] = saved
            if !saved.isEmpty {
                transcribing.remove(key)
                environment.common.wordMarks.prepare(saved.map { TappableLine.sentence($0.text) })
            }
        }
    }

    /// Asks Kaku for the transcripts of marked episodes that don't have one on the device yet
    /// (and to start one that's missing). Offline, they stay "Transcribing".
    private func fetchTranscripts() async {
        guard let kaku = environment.kakuClient() else { return }
        let waiting = Dictionary(marks.filter { sentences[$0.key]?.isEmpty ?? true }.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        for (key, mark) in waiting where !asked.contains(key) {
            asked.insert(key)
            transcribing.insert(key)
            switch try? await kaku.transcript(itemId: mark.itemId, episodeId: mark.episodeId) {
            case .ready(let document):
                if let saved = try? environment.saveTranscript(document, itemId: mark.itemId, episodeId: mark.episodeId,
                                                               showTitle: mark.showTitle, episodeTitle: mark.episodeTitle, played: true) {
                    sentences[key] = saved
                    transcribing.remove(key)
                    environment.common.wordMarks.prepare(saved.map { TappableLine.sentence($0.text) })
                }
            case .missing:
                _ = try? await kaku.requestJob(itemId: mark.itemId, episodeId: mark.episodeId)
            case .pending, nil:
                break
            }
        }
    }

    // MARK: Audio

    /// The episode's audio: the player's when it's the one loaded, else found once here.
    private func audio(for mark: AudioMark) async -> EpisodeAudio? {
        if let playback = environment.playback, playback.key == mark.key { return playback.episodeAudio }
        if let audio = audios[mark.key] { return audio }
        guard let entry = await environment.entry(itemId: mark.itemId, episodeId: mark.episodeId, showTitle: mark.showTitle) else {
            problem = "Couldn't find this episode. Connect to Audiobookshelf or download it."
            return nil
        }
        let audio = EpisodeAudio(entry: entry)
        if let failure = await audio.resolve(environment: environment) {
            problem = failure
            return nil
        }
        audios[mark.key] = audio
        return audio
    }

    /// Plays (or stops) the 15 seconds before the mark.
    func playClip(of mark: AudioMark) async {
        if clip.isPlaying, playingMark == mark.id {
            clip.stop()
            return
        }
        guard let audio = await audio(for: mark) else { return }
        // Hearing the clip pauses the episode (it stays paused: you're in Marks).
        environment.playback?.audio.pause()
        clip.stop()
        audio.playClip(clip, from: mark.time - Self.clipLength, to: mark.time)
        playingMark = mark.id
    }

    func clear(_ mark: AudioMark) {
        guard let id = mark.id else { return }
        try? environment.marks.remove(id)
    }

    // MARK: Lookup

    /// Looks up the word in one of a mark's lines; a card mined from it is recorded on the mark.
    func tap(_ sentence: AudioSentence, of mark: AudioMark, characterIndex: Int) async {
        let audio = await audio(for: mark)
        problem = nil
        pausePlayer()
        lookupSentence = sentence
        let miscInfo = CardSource.miscInfo(show: mark.showTitle, episode: mark.episodeTitle, time: sentence.start)
        let base = audio?.miningContext(for: sentence) ?? TextMiningContext(miscInfo: miscInfo)
        let marks = environment.marks
        let context = MarkMiningContext(base: base) { mined in
            if let id = mark.id { try? marks.setMined(id, word: mined.expression, jobId: mined.jobId) }
        }
        lookup.lookUp(sentence.text, characterIndex: characterIndex, key: "\(mark.id ?? 0)-\(sentence.position)", context: context)
    }

    var resumesOnClose: Bool { resumesAfterLookup }

    func playClip(_ sentence: AudioSentence) {
        guard let audio = audios[sentence.key] ?? (environment.playback?.key == sentence.key ? environment.playback?.episodeAudio : nil) else { return }
        playingMark = nil
        audio.playClip(clip, from: sentence.start - AudioMiningContext.leadIn, to: sentence.end + AudioMiningContext.tail)
    }

    func popupClosed() {
        lookup.close()
        clip.stop()
        lookupSentence = nil
        if resumesAfterLookup {
            resumesAfterLookup = false
            environment.playback?.audio.play()
        }
    }

    /// Tapping a word pauses what's playing; closing the lookup resumes it.
    private func pausePlayer() {
        guard let player = environment.playback?.audio, player.isPlaying else { return }
        resumesAfterLookup = true
        player.pause()
    }

    /// Leaving the tab: stop the clip and delete temporary copies of streams.
    func discard() {
        clip.stop()
        playingMark = nil
        for audio in audios.values { audio.discard() }
        audios = [:]
    }
}

/// A line's card media, plus recording on the mark that the card was mined.
struct MarkMiningContext: MiningContext {
    let base: any MiningContext
    let onMined: @MainActor @Sendable (MiningService.Mined) -> Void

    func pictureData() async -> Data? { await base.pictureData() }
    var miscInfo: String { base.miscInfo }
    func sentenceAudio() async -> SentenceAudio? { await base.sentenceAudio() }
    func cardMedia() async -> CardMedia { await base.cardMedia() }
    var seriesKey: String? { base.seriesKey }
    var seriesTitle: String? { base.seriesTitle }
    func mined(_ mined: MiningService.Mined) async { await onMined(mined) }
}
