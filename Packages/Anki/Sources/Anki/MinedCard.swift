import Core
import Foundation

/// A mined card waiting in the outbox. It holds the card's content, not Anki
/// field names: the field mapping is applied when it's sent, so fixing the
/// mapping in Settings fixes cards that failed because of it.
public struct MinedCard: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version = MinedCard.currentVersion
    public var expression: String
    public var reading: String
    /// The values for each text slot (everything except audio and picture).
    public var content: [AnkiContentSlot: String]
    public var deck: String
    public var noteType: String
    public var tags: [String]
    public var allowDuplicate: Bool
    /// Word audio is looked up when the card is sent, so mining works offline.
    public var wantsAudio: Bool
    /// Media the source should have had but couldn't make (e.g. a failed screenshot), shown in
    /// the Queue. Nil when nothing is missing.
    public var mediaProblems: [String]?
    /// Where it was mined (series id and title), for Stats. Nil on cards from before Stats.
    public var seriesKey: String?
    public var seriesTitle: String?

    public init(
        expression: String, reading: String, content: [AnkiContentSlot: String], deck: String, noteType: String,
        tags: [String], allowDuplicate: Bool = false, wantsAudio: Bool = true
    ) {
        self.expression = expression
        self.reading = reading
        self.content = content
        self.deck = deck
        self.noteType = noteType
        self.tags = tags
        self.allowDuplicate = allowDuplicate
        self.wantsAudio = wantsAudio
    }

    /// The media slot names used for `OutboxMedia.field`.
    public static let pictureMedia = "picture"
    public static let sentenceAudioMedia = "sentenceAudio"
}

/// Builds the AnkiConnect note for a card.
public enum AnkiNoteBuilder {
    public struct Result: Equatable, Sendable {
        public var note: AnkiNote
        /// Mapped fields that the note type doesn't have.
        public var missingFields: [String]
    }

    public enum BuildError: Error, Equatable, LocalizedError {
        case noWordField
        public var errorDescription: String? {
            "No field of the note type gets the word. Check the field mapping in Settings → AnkiConnect."
        }
    }

    public static func note(
        for card: MinedCard, mapping: [String: AnkiFieldSource], fieldNames: [String],
        pictureFile: String?, audioFile: String?, sentenceAudioFile: String? = nil
    ) throws -> Result {
        let existing = mapping.filter { fieldNames.contains($0.key) }
        guard existing.values.contains(.slot(.expression)) else { throw BuildError.noWordField }

        var fields: [String: String] = [:]
        for (field, source) in existing {
            switch source {
            case .constant(let text):
                fields[field] = text
            case .slot(.picture):
                fields[field] = pictureFile.map { "<img src=\"\(CardFormatting.escape($0))\">" } ?? ""
            case .slot(.audio):
                fields[field] = audioFile.map { "[sound:\($0)]" } ?? ""
            case .slot(.sentenceAudio):
                fields[field] = sentenceAudioFile.map { "[sound:\($0)]" } ?? ""
            case .slot(let slot):
                fields[field] = slot == .expression ? card.expression : slot == .reading ? card.reading : card.content[slot] ?? ""
            }
        }
        let note = AnkiNote(deckName: card.deck, modelName: card.noteType, fields: fields, tags: card.tags, allowDuplicate: card.allowDuplicate)
        return Result(note: note, missingFields: mapping.keys.filter { !fieldNames.contains($0) }.sorted())
    }
}
