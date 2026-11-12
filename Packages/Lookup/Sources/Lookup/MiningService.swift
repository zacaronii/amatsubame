import Anki
import Core
import Dictionary
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// What a reader adds to cards mined from it.
public protocol MiningContext: Sendable {
    /// The picture for the card (e.g. the current page), any image format.
    func pictureData() async -> Data?
    /// Where the word was found, for the MiscInfo field.
    var miscInfo: String { get }
    /// The spoken sentence (video), for the SentenceAudio field.
    func sentenceAudio() async -> SentenceAudio?
    /// Both of the above, and what couldn't be made (see the default below).
    func cardMedia() async -> CardMedia
    /// The series (Kavita id, Jellyfin series id) and its title, for Stats' cards per series.
    var seriesKey: String? { get }
    var seriesTitle: String? { get }
    /// Called once the card is queued (Kiku records it on the mark it came from).
    func mined(_ mined: MiningService.Mined) async
}

extension MiningContext {
    public func sentenceAudio() async -> SentenceAudio? { nil }
    public var seriesKey: String? { nil }
    public var seriesTitle: String? { nil }
    public func mined(_ mined: MiningService.Mined) async {}

    /// The picture and sentence audio together, and what couldn't be made. A video context
    /// makes both from one read of the source.
    public func cardMedia() async -> CardMedia {
        CardMedia(picture: await pictureData(), audio: await sentenceAudio())
    }
}

/// A card's picture and sentence audio, with a note for anything a context expected but
/// couldn't make (shown on the card in the Queue).
public struct CardMedia: Sendable {
    public var picture: Data?
    /// An animated GIF goes on the card as it is; anything else is made a JPEG of the set size.
    public var pictureIsAnimated: Bool
    public var audio: SentenceAudio?
    /// For example "No picture: the clip came out empty."
    public var problems: [String]

    public init(picture: Data?, pictureIsAnimated: Bool = false, audio: SentenceAudio?, problems: [String] = []) {
        self.picture = picture
        self.pictureIsAnimated = pictureIsAnimated
        self.audio = audio
        self.problems = problems
    }
}

/// An audio file for a card, e.g. an AAC `.m4a` clip of a subtitle line.
public struct SentenceAudio: Sendable {
    public var data: Data
    public var fileExtension: String

    public init(data: Data, fileExtension: String) {
        self.data = data
        self.fileExtension = fileExtension
    }
}

/// Turns dictionary entries into Anki cards. Mining never touches the network:
/// the card goes into the outbox, and `AnkiNoteHandler` sends it later.
@MainActor @Observable
public final class MiningService {
    /// How long a new card waits before it's sent, so Undo works even online.
    public static let undoWindow: TimeInterval = 5

    public struct Mined: Equatable, Sendable {
        public var jobId: Int64
        public var expression: String
    }

    let outbox: OutboxStore
    let media: OutboxMediaStorage
    public let settingsStore: AnkiSettingsStore
    public let minedWords: MinedWordStore
    /// Wakes the outbox worker.
    let onQueued: @MainActor () -> Void
    /// Bumped when the set of mined words changes, so open popups can re-check.
    public private(set) var revision = 0
    /// Called when a queued card is taken back (Undo), with its outbox job.
    @ObservationIgnored public var onCancelled: (@MainActor (Int64) -> Void)?

    public init(
        outbox: OutboxStore, media: OutboxMediaStorage, settings: AnkiSettingsStore, minedWords: MinedWordStore,
        onQueued: @escaping @MainActor () -> Void = {}
    ) {
        self.outbox = outbox
        self.media = media
        settingsStore = settings
        self.minedWords = minedWords
        self.onQueued = onQueued
    }

    public func isMined(_ result: TermLookupResult) -> Bool {
        (try? minedWords.contains(expression: result.expression, reading: result.reading)) ?? false
    }

    /// Queues a card for `result`. `sentence` is the text around the word; the
    /// context adds the picture and source.
    public func mine(
        _ result: TermLookupResult, sentence: String?, context: (any MiningContext)?, allowDuplicate: Bool = false
    ) async throws -> Mined {
        let settings = try settingsStore.settings()
        var card = Self.card(for: result, sentence: sentence, miscInfo: context?.miscInfo, settings: settings, allowDuplicate: allowDuplicate)
        var mediaInputs: [OutboxMediaInput] = []
        let cardMedia = await context?.cardMedia() ?? CardMedia(picture: nil, audio: nil)
        var problems = cardMedia.problems
        if let picture = cardMedia.picture, cardMedia.pictureIsAnimated {
            mediaInputs.append(OutboxMediaInput(field: MinedCard.pictureMedia, filename: try media.store(picture, fileExtension: "gif")))
        } else if let picture = cardMedia.picture {
            if let jpeg = Self.jpeg(from: picture, maxPixels: settings.pictureMaxPixels) {
                mediaInputs.append(OutboxMediaInput(field: MinedCard.pictureMedia, filename: try media.store(jpeg, fileExtension: "jpg")))
            } else {
                problems.append("No picture: it couldn't be converted to JPEG.")
            }
        }
        card.mediaProblems = problems.isEmpty ? nil : problems
        card.seriesKey = context?.seriesKey
        card.seriesTitle = context?.seriesTitle
        if let audio = cardMedia.audio {
            mediaInputs.append(OutboxMediaInput(
                field: MinedCard.sentenceAudioMedia, filename: try media.store(audio.data, fileExtension: audio.fileExtension)))
        }
        let id = try outbox.enqueue(card, kind: .ankiNote, media: mediaInputs, notBefore: Date().addingTimeInterval(Self.undoWindow))
        try? minedWords.markQueued(expression: result.expression, reading: result.reading, jobId: id)
        revision += 1
        onQueued()
        let mined = Mined(jobId: id, expression: result.expression)
        await context?.mined(mined)
        return mined
    }

    /// Removes a card that hasn't been sent yet. Returns false if it's already on its way.
    @discardableResult
    public func cancel(_ jobId: Int64) -> Bool {
        guard let files = try? outbox.cancel(jobId) else { return false }
        media.remove(files)
        try? minedWords.removeQueued(jobId: jobId)
        revision += 1
        onCancelled?(jobId)
        return true
    }

    /// Reloads the words in the mining deck (for the popup's check and word marks): every
    /// note in the deck from Settings ▸ Cards, and which have a card with an interval of 21
    /// days or more (known). The rest are learning, including new cards not studied yet.
    public func refreshMinedWords(using client: AnkiConnectClient) async throws {
        let settings = try settingsStore.settings()
        let wordField = settings.fields.first { $0.value == .slot(.expression) }?.key
        let readingField = settings.fields.first { $0.value == .slot(.reading) }?.key
        guard let wordField else { return }
        let deck = "deck:\"\(Self.searchEscaped(settings.deck))\""
        let ids = try await client.findNotes(deck)
        let known = Set(try await client.findNotes("\(deck) prop:ivl>=21"))
        var words: [(expression: String, reading: String, known: Bool)] = []
        for start in stride(from: 0, to: ids.count, by: 500) {
            let notes = try await client.notesInfo(Array(ids[start..<min(start + 500, ids.count)]))
            for note in notes {
                guard let expression = note.fields[wordField]?.value.plainWord, !expression.isEmpty else { continue }
                words.append((expression, readingField.flatMap { note.fields[$0]?.value.plainWord } ?? "", known.contains(note.noteId)))
            }
        }
        // Other decks chosen for marks: notes with a studied card (never-studied premade cards
        // stay "not in Anki"); the word is the note's first field.
        var others: [(expression: String, reading: String, known: Bool)] = []
        for other in settings.markDecks where other != settings.deck {
            let search = "deck:\"\(Self.searchEscaped(other))\""
            let studied = try await client.findNotes("\(search) -is:new")
            let known = Set(try await client.findNotes("\(search) prop:ivl>=21"))
            for start in stride(from: 0, to: studied.count, by: 500) {
                for note in try await client.notesInfo(Array(studied[start..<min(start + 500, studied.count)])) {
                    guard let expression = note.firstFieldValue?.plainWord, !expression.isEmpty else { continue }
                    others.append((expression, "", known.contains(note.noteId)))
                }
            }
        }
        try minedWords.replaceAnkiWords(words, others: others)
        revision += 1
    }

    /// The mined words' states, for marking text.
    public func wordMarks() -> WordMarks {
        (try? minedWords.marks()) ?? .empty
    }

    /// Whether word marks are on (Settings ▸ Lookup), read once and kept with the setting.
    public var marksWords: Bool {
        if let cachedMarksWords { return cachedMarksWords }
        let value = (try? settingsStore.settings().marksWords) ?? true
        cachedMarksWords = value
        return value
    }
    @ObservationIgnored private var cachedMarksWords: Bool?

    /// Turns word marks on or off; marked text redraws.
    public func setMarksWords(_ on: Bool) {
        guard var settings = try? settingsStore.settings() else { return }
        settings.marksWords = on
        try? settingsStore.save(settings)
        cachedMarksWords = on
        revision += 1
    }

    /// A deck name inside an Anki search's quotes.
    nonisolated static func searchEscaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: Building cards

    nonisolated static func card(
        for result: TermLookupResult, sentence: String?, miscInfo: String?, settings: AnkiSettings, allowDuplicate: Bool
    ) -> MinedCard {
        let reading = result.reading.isEmpty ? result.expression : result.reading
        let downsteps = result.pitches.first { !$0.accents.isEmpty }?.accents.map(\.downstep) ?? []
        let items = result.glossaries.map { glossary in
            CardFormatting.GlossaryItem(
                dictionary: glossary.dictionary, tags: glossary.definitionTags,
                html: Self.withoutDictionaryImages(StructuredContentRenderer(dictionary: glossary.dictionary).render(glossaryJSON: glossary.json))
            )
        }
        let firstDictionary = items.first?.dictionary
        // From the first dictionary with glosses, so a prose dictionary first doesn't leave it empty.
        // JMdict's "forms" entry lists spellings (事態, 事体), not a meaning.
        let meanings = result.glossaries.filter { !$0.definitionTags.contains("forms") }
        let glossesByDictionary = Dictionary(grouping: meanings, by: \.dictionary)
            .mapValues { $0.flatMap { StructuredContentRenderer.glosses(glossaryJSON: $0.json) } }
        let shortSenses = meanings.lazy.map(\.dictionary).compactMap { glossesByDictionary[$0] }.first { !$0.isEmpty } ?? []
        var content: [AnkiContentSlot: String] = [
            .furigana: CardFormatting.furigana(expression: result.expression, reading: result.reading),
            .mainDefinition: CardFormatting.glossary(items.filter { $0.dictionary == firstDictionary }),
            .glossary: CardFormatting.glossary(items),
            .shortDefinition: CardFormatting.shortDefinition(shortSenses),
            .pitchPosition: CardFormatting.pitchPosition(downsteps: downsteps),
            .pitchCategories: CardFormatting.pitchCategories(downsteps: downsteps, expression: result.expression, reading: reading, rules: result.rules),
            .frequency: CardFormatting.frequencyList(result.frequencies),
            .freqSort: CardFormatting.frequencySort(result.frequencies),
        ]
        if let sentence, !sentence.isEmpty {
            content[.sentence] = CardFormatting.boldedSentence(sentence, match: result.matched.isEmpty ? result.expression : result.matched)
        }
        if let miscInfo, !miscInfo.isEmpty { content[.miscInfo] = CardFormatting.escape(miscInfo) }
        return MinedCard(
            expression: result.expression, reading: result.reading, content: content, deck: settings.deck,
            noteType: settings.noteType, tags: settings.tags, allowDuplicate: allowDuplicate
        )
    }

    /// Dictionary images are served from the app (`dictmedia://`) and wouldn't load in Anki.
    nonisolated static func withoutDictionaryImages(_ html: String) -> String {
        html.replacingOccurrences(of: "<img[^>]*\(StructuredContentRenderer.mediaScheme)://[^>]*>", with: "", options: .regularExpression)
    }

    /// The image re-encoded as JPEG, its longest side at most `maxPixels`.
    nonisolated static func jpeg(from data: Data, maxPixels: Int) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixels,
              ] as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }
}

extension String {
    /// A field's word as plain text: no HTML, and no bracket furigana (`食[た]べる` → `食べる`).
    var plainWord: String {
        strippingHTML.replacingOccurrences(of: #"\[[^\]]*\]"#, with: "", options: .regularExpression)
            .filter { !$0.isWhitespace }
    }

    var strippingHTML: String {
        replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
