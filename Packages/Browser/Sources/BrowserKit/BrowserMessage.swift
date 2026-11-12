import Foundation

/// A message from the extension's JavaScript (via `browser.runtime.sendNativeMessage`).
public enum BrowserRequest: Equatable, Sendable {
    /// A tap: the block's text (furigana removed), the tapped character's UTF-16 offset, and
    /// the page it's on (for the card's source).
    case lookup(text: String, offset: Int, title: String?, url: String?)
    /// A glossary link: look up this word.
    case query(String)
    /// The audio of result `index` of lookup `id`.
    case audio(id: String, index: Int)
    /// Make a card from result `index` of lookup `id` (queued; it can be undone for a few seconds).
    case mine(id: String, index: Int)
    /// Take back a card just made.
    case undo(jobId: Int64)
    /// Send the card `jobId` (and anything else due) to Anki, after the undo window.
    case send(jobId: Int64)
    /// Dictionaries, AnkiConnect and the extension's memory use.
    case status
    /// AnkiConnect, set in the extension's menu (until the App Group lets Hiku do it).
    case saveAnki(url: String, apiKey: String, deck: String)
    /// Word marks for a page's paragraphs (texts without furigana), as in Yomu's books.
    case marks(texts: [String])

    /// Paragraphs per marks message, and the most of each that's split into words.
    static let maxMarkTexts = 40
    static let maxMarkTextLength = 4000

    public init?(_ message: Any?) {
        guard let message = message as? [String: Any], let action = message["action"] as? String else { return nil }
        let string = { (key: String) in message[key] as? String }
        switch action {
        case "lookup":
            guard let text = string("text"), let offset = Self.int(message["offset"]),
                  offset >= 0, offset < text.utf16.count else { return nil }
            self = .lookup(text: text, offset: offset, title: string("title"), url: string("url"))
        case "query":
            guard let query = string("query"), !query.isEmpty else { return nil }
            self = .query(query)
        case "audio", "mine":
            guard let id = string("id"), let index = Self.int(message["index"]), index >= 0 else { return nil }
            self = action == "audio" ? .audio(id: id, index: index) : .mine(id: id, index: index)
        case "undo":
            guard let jobId = Self.int(message["jobId"]) else { return nil }
            self = .undo(jobId: Int64(jobId))
        case "send":
            guard let jobId = Self.int(message["jobId"]) else { return nil }
            self = .send(jobId: Int64(jobId))
        case "status":
            self = .status
        case "saveAnki":
            guard let url = string("url") else { return nil }
            self = .saveAnki(url: url, apiKey: string("apiKey") ?? "", deck: string("deck") ?? "")
        case "marks":
            guard let texts = message["texts"] as? [String], !texts.isEmpty, texts.count <= Self.maxMarkTexts else { return nil }
            self = .marks(texts: texts.map { String($0.utf16.prefix(Self.maxMarkTextLength)) ?? $0 })
        default:
            return nil
        }
    }

    /// JavaScript numbers arrive as Int or Double depending on the bridge.
    static func int(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let int = value as? Int64 { return Int(int) }
        if let double = value as? Double, double.rounded() == double { return Int(double) }
        return nil
    }
}
