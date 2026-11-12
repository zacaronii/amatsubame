import Core
import Foundation

/// A note for AnkiConnect's `addNote`. Only AnkiConnect's own keys are encoded:
/// some AnkiConnect-compatible proxies reject unknown ones.
public struct AnkiNote: Encodable, Equatable, Sendable {
    public struct Options: Encodable, Equatable, Sendable {
        public var allowDuplicate: Bool
        /// Duplicates are checked within the target deck.
        public var duplicateScope = "deck"
    }

    public var deckName: String
    public var modelName: String
    public var fields: [String: String]
    public var tags: [String]
    public var options: Options

    // Media goes up first with `storeMediaFile` and the fields reference it: some
    // AnkiConnect-compatible proxies accept addNote's `picture`/`audio` arrays but silently drops them.
    public init(deckName: String, modelName: String, fields: [String: String], tags: [String], allowDuplicate: Bool) {
        self.deckName = deckName
        self.modelName = modelName
        self.fields = fields
        self.tags = tags
        options = Options(allowDuplicate: allowDuplicate)
    }
}

/// `notesInfo`, reduced to what the app reads.
public struct AnkiNoteInfo: Decodable, Equatable, Sendable {
    public struct Field: Decodable, Equatable, Sendable {
        public var value: String
        /// The field's position in the note type (0 = first).
        public var order: Int?
    }

    public var noteId: Int64
    public var modelName: String
    public var fields: [String: Field]

    /// The note's first field (its sort field in most note types: the word in a vocab deck).
    public var firstFieldValue: String? {
        fields.values.min { ($0.order ?? .max) < ($1.order ?? .max) }?.value
    }
}

/// Why `addNote` failed, sorted by whether retrying can help.
public enum AnkiAddNoteError: Error, Equatable, LocalizedError {
    case duplicate
    /// The note type, deck or fields don't match; needs the user.
    case rejected(String)
    case connection(ConnectionError)

    init(_ error: ConnectionError) {
        guard case .message(let text) = error, text.hasPrefix(AnkiConnectClient.prefix) else {
            self = .connection(error)
            return
        }
        let detail = String(text.dropFirst(AnkiConnectClient.prefix.count))
        self = detail.localizedCaseInsensitiveContains("duplicate") ? .duplicate : .rejected(detail)
    }

    public var errorDescription: String? {
        switch self {
        case .duplicate: "Already in Anki."
        case .rejected(let detail): "Anki rejected the card: \(detail)"
        case .connection(let error): error.localizedDescription
        }
    }
}
