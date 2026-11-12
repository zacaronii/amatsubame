import Foundation
import GRDB

/// A piece of a mined card that can fill an Anki field.
public enum AnkiContentSlot: String, Codable, CaseIterable, Sendable {
    case expression, furigana, reading, audio, mainDefinition, glossary, sentence, picture
    /// The spoken line, from video (the Player); empty for readers.
    case sentenceAudio
    case pitchPosition, pitchCategories, frequency, freqSort, miscInfo
    /// A glanceable line: the first senses' glosses, without examples or notes.
    case shortDefinition

    public var displayName: String {
        switch self {
        case .expression: "Word"
        case .furigana: "Word with furigana"
        case .reading: "Reading"
        case .audio: "Word audio"
        case .mainDefinition: "Main definition"
        case .glossary: "All definitions"
        case .sentence: "Sentence"
        case .picture: "Picture"
        case .sentenceAudio: "Sentence audio"
        case .pitchPosition: "Pitch accent"
        case .pitchCategories: "Pitch category"
        case .frequency: "Frequencies"
        case .freqSort: "Frequency sort value"
        case .miscInfo: "Source"
        case .shortDefinition: "Short definition"
        }
    }
}

/// What goes into one Anki field.
public enum AnkiFieldSource: Codable, Equatable, Hashable, Sendable {
    case slot(AnkiContentSlot)
    /// Fixed text, e.g. `x` in Lapis' card-type switches.
    case constant(String)
}

/// How mined cards are made: where they go and which field gets what.
public struct AnkiSettings: Codable, Equatable, Sendable {
    public var deck: String
    public var noteType: String
    /// Field name → content. Fields not listed stay empty.
    public var fields: [String: AnkiFieldSource]
    public var tags: [String]
    /// Longest side of the page picture, in pixels.
    public var pictureMaxPixels: Int
    /// Ask the AnkiConnect server to sync with AnkiWeb after cards are added.
    public var syncAfterAdding: Bool
    /// Underline words in books and subtitles by their state in the mining deck (Settings ▸ Lookup).
    public var marksWords: Bool
    /// Other decks whose studied cards count for word marks (e.g. a premade vocab deck). Their
    /// word is each note's first field; they don't count as mined.
    public var markDecks: [String]

    public init(
        deck: String, noteType: String, fields: [String: AnkiFieldSource], tags: [String],
        pictureMaxPixels: Int = 1600, syncAfterAdding: Bool = false, marksWords: Bool = true, markDecks: [String] = []
    ) {
        self.deck = deck
        self.noteType = noteType
        self.fields = fields
        self.tags = tags
        self.pictureMaxPixels = pictureMaxPixels
        self.syncAfterAdding = syncAfterAdding
        self.marksWords = marksWords
        self.markDecks = markDecks
    }

    enum CodingKeys: String, CodingKey {
        case deck, noteType, fields, tags, pictureMaxPixels, syncAfterAdding, marksWords, markDecks, fieldsVersion
    }

    /// Raised when the Lapis preset gains a field, so older settings gain it once (and keep
    /// "Nothing" if it's later chosen). 2: SelectionText ← short definition.
    static let fieldsVersion = 2

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(deck, forKey: .deck)
        try container.encode(noteType, forKey: .noteType)
        try container.encode(fields, forKey: .fields)
        try container.encode(tags, forKey: .tags)
        try container.encode(pictureMaxPixels, forKey: .pictureMaxPixels)
        try container.encode(syncAfterAdding, forKey: .syncAfterAdding)
        try container.encode(marksWords, forKey: .marksWords)
        try container.encode(markDecks, forKey: .markDecks)
        try container.encode(Self.fieldsVersion, forKey: .fieldsVersion)
    }

    /// Settings saved by an older version keep the new defaults.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        deck = try container.decode(String.self, forKey: .deck)
        noteType = try container.decode(String.self, forKey: .noteType)
        fields = try container.decode([String: AnkiFieldSource].self, forKey: .fields)
        tags = try container.decode([String].self, forKey: .tags)
        pictureMaxPixels = try container.decodeIfPresent(Int.self, forKey: .pictureMaxPixels) ?? 1600
        syncAfterAdding = try container.decodeIfPresent(Bool.self, forKey: .syncAfterAdding) ?? false
        marksWords = try container.decodeIfPresent(Bool.self, forKey: .marksWords) ?? true
        markDecks = try container.decodeIfPresent([String].self, forKey: .markDecks) ?? []
        // Lapis mappings saved before sentence audio existed gain it (the field was left empty).
        if noteType == "Lapis", fields["SentenceAudio"] == nil, fields["Sentence"] != nil {
            fields["SentenceAudio"] = .slot(.sentenceAudio)
        }
        // Lapis shows SelectionText first when it's filled; older mappings left it empty.
        let version = try container.decodeIfPresent(Int.self, forKey: .fieldsVersion) ?? 1
        if version < 2, noteType == "Lapis", fields["SelectionText"] == nil, fields["MainDefinition"] != nil {
            fields["SelectionText"] = .slot(.shortDefinition)
        }
    }

    /// The Lapis note type, filled the way Yomitan's Lapis setup does (word + sentence card).
    public static let lapisFields: [String: AnkiFieldSource] = [
        "Expression": .slot(.expression),
        "ExpressionFurigana": .slot(.furigana),
        "ExpressionReading": .slot(.reading),
        "ExpressionAudio": .slot(.audio),
        "MainDefinition": .slot(.mainDefinition),
        // Shown first on the card; MainDefinition and Glossary are a tap away.
        "SelectionText": .slot(.shortDefinition),
        "Sentence": .slot(.sentence),
        "Picture": .slot(.picture),
        "SentenceAudio": .slot(.sentenceAudio),
        "Glossary": .slot(.glossary),
        "IsWordAndSentenceCard": .constant("x"),
        "PitchPosition": .slot(.pitchPosition),
        "PitchCategories": .slot(.pitchCategories),
        "Frequency": .slot(.frequency),
        "FreqSort": .slot(.freqSort),
        "MiscInfo": .slot(.miscInfo),
    ]

    public static let `default` = AnkiSettings(deck: "日本語::Mining", noteType: "Lapis", fields: lapisFields, tags: ["amatsubame"])

    /// Default fields for a note type: the Lapis preset where its names exist,
    /// otherwise the word in the first field and the sentence in a field called Sentence.
    public static func presetFields(for fieldNames: [String]) -> [String: AnkiFieldSource] {
        let lapis = lapisFields.filter { fieldNames.contains($0.key) }
        if !lapis.isEmpty { return lapis }
        var fields: [String: AnkiFieldSource] = [:]
        if let first = fieldNames.first { fields[first] = .slot(.expression) }
        if let sentence = fieldNames.first(where: { $0.caseInsensitiveCompare("Sentence") == .orderedSame }) {
            fields[sentence] = .slot(.sentence)
        }
        return fields
    }
}

struct AnkiSettingsRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "ankiSettings"
    var id = 1
    var settings: Data
}

public struct AnkiSettingsStore: Sendable {
    public let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func settings() throws -> AnkiSettings {
        try database.reader.read { db in
            guard let row = try AnkiSettingsRow.fetchOne(db, key: 1) else { return .default }
            return try JSONDecoder().decode(AnkiSettings.self, from: row.settings)
        }
    }

    public func save(_ settings: AnkiSettings) throws {
        let row = AnkiSettingsRow(settings: try JSONEncoder().encode(settings))
        try database.writer.write { try row.save($0) }
    }
}

/// A word that's in Anki, or queued to go there, so the popup can mark it.
public struct MinedWordRecord: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "minedWord"

    public enum Source: String, Codable, Sendable {
        /// Seen in Anki (sent from here or mined elsewhere).
        case anki
        /// Mined here and still in the outbox.
        case queued
        /// A studied card in another deck chosen for word marks (`AnkiSettings.markDecks`):
        /// marked, but not "already mined".
        case otherDeck
    }

    public var expression: String
    public var reading: String
    public var source: Source
    public var jobId: Int64?
    public var updatedAt: Date
    /// Its card's review interval is 21 days or more. Queued words are still learning.
    public var known: Bool

    public init(expression: String, reading: String, source: Source, jobId: Int64? = nil, updatedAt: Date = Date(), known: Bool = false) {
        self.expression = expression
        self.reading = reading
        self.source = source
        self.jobId = jobId
        self.updatedAt = updatedAt
        self.known = known
    }
}

/// How a word is marked in books and subtitles. There's no "due": reviews happen in Anki.
public enum WordMarkState: String, Codable, Sendable {
    /// No note for it in the mining deck: a solid underline in the app's accent.
    case notInAnki
    /// In the deck with an interval under 21 days, or mined and not studied yet: a dotted grey underline.
    case learning
    /// An interval of 21 days or more: no mark.
    case known
}

/// A snapshot of the mined words, for marking many words at once without a query each.
public struct WordMarks: Sendable {
    /// Expression → (reading, known) for each mined reading of it.
    private let words: [String: [(reading: String, known: Bool)]]

    public init(_ records: [MinedWordRecord]) {
        words = Dictionary(grouping: records, by: \.expression).mapValues { $0.map { ($0.reading, $0.known) } }
    }

    public static let empty = WordMarks([])

    /// An empty reading in Anki matches any reading; known only when the matching notes are.
    public func state(expression: String, reading: String) -> WordMarkState {
        let matching = (words[expression] ?? []).filter { $0.reading == reading || $0.reading.isEmpty || reading.isEmpty }
        if matching.isEmpty { return .notInAnki }
        return matching.contains { $0.known } ? .known : .learning
    }
}

public struct MinedWordStore: Sendable {
    public let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    /// Whether this word is in the mining deck or queued. An empty reading in Anki matches any reading.
    public func contains(expression: String, reading: String) throws -> Bool {
        try database.reader.read { db in
            try MinedWordRecord
                .filter(Column("expression") == expression)
                .filter(Column("source") != MinedWordRecord.Source.otherDeck.rawValue)
                .filter([reading, ""].contains(Column("reading")))
                .fetchCount(db) > 0
        }
    }

    public func markQueued(expression: String, reading: String, jobId: Int64) throws {
        try database.writer.write { db in
            // A word already known to be in Anki stays marked as such.
            if let existing = try MinedWordRecord.fetchOne(db, key: ["expression": expression, "reading": reading]),
               existing.source == .anki { return }
            try MinedWordRecord(expression: expression, reading: reading, source: .queued, jobId: jobId).save(db)
        }
    }

    public func markInAnki(expression: String, reading: String) throws {
        try database.writer.write { db in
            // A duplicate of a known card stays known.
            let known = try MinedWordRecord.fetchOne(db, key: ["expression": expression, "reading": reading])?.known ?? false
            try MinedWordRecord(expression: expression, reading: reading, source: .anki, known: known).save(db)
        }
    }

    /// Forgets a queued word whose card was cancelled or deleted.
    public func removeQueued(jobId: Int64) throws {
        _ = try database.writer.write { db in
            try MinedWordRecord.filter(Column("jobId") == jobId && Column("source") == MinedWordRecord.Source.queued.rawValue).deleteAll(db)
        }
    }

    /// Replaces the words known to be in Anki with what's there now: the mining deck's, and the
    /// other decks' (`others`) where the mining deck doesn't have the word. Queued words are kept
    /// (a queued word that's now in Anki becomes an Anki word). Known wins when a word is in both.
    public func replaceAnkiWords(_ words: [(expression: String, reading: String, known: Bool)],
                                 others: [(expression: String, reading: String, known: Bool)] = []) throws {
        let now = Date()
        var records: [String: MinedWordRecord] = [:]
        for (source, list) in [(MinedWordRecord.Source.anki, words), (.otherDeck, others)] {
            for word in list {
                let key = word.expression + "\u{1F}" + word.reading
                if var existing = records[key] {
                    existing.known = existing.known || word.known
                    records[key] = existing
                } else {
                    records[key] = MinedWordRecord(expression: word.expression, reading: word.reading, source: source, updatedAt: now, known: word.known)
                }
            }
        }
        try database.writer.write { db in
            _ = try MinedWordRecord.filter([MinedWordRecord.Source.anki.rawValue, MinedWordRecord.Source.otherDeck.rawValue]
                .contains(Column("source"))).deleteAll(db)
            for record in records.values { try record.save(db) }
        }
    }

    /// Every mined word, for marking text.
    public func marks() throws -> WordMarks {
        try database.reader.read { WordMarks(try MinedWordRecord.fetchAll($0)) }
    }

    public func count() throws -> Int {
        try database.reader.read { try MinedWordRecord.fetchCount($0) }
    }
}
