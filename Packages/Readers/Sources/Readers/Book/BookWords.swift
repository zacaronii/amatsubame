import CryptoKit
import Dictionary
import Foundation

/// The words of one section of a book, for word marks: its runs of text split by
/// `WordScanner`, cached in the book's folder (`.words-v1-<section>.json`) next to the
/// character index, so a section is split once per book.
enum BookWords {
    struct Cache: Codable {
        /// The runs' texts, hashed: a different book file or script splits again.
        var textHash: String
        var runs: [[WordSpan]]
    }

    static func words(texts: [String], section: Int, folder: URL?, scanner: WordScanner) async -> [[WordSpan]] {
        let hash = SHA256.hash(data: Data(texts.joined(separator: "\u{1E}").utf8)).map { String(format: "%02x", $0) }.joined()
        let file = folder?.appending(path: ".words-v1-\(section).json")
        if let file, let data = try? Data(contentsOf: file),
           let cache = try? JSONDecoder().decode(Cache.self, from: data), cache.textHash == hash, cache.runs.count == texts.count {
            return cache.runs
        }
        var runs: [[WordSpan]] = []
        for text in texts { runs.append(await scanner.words(in: text)) }
        // Not saved before the dictionaries load (it would be all empty).
        if await scanner.isReady, let file, let data = try? JSONEncoder().encode(Cache(textHash: hash, runs: runs)) {
            try? data.write(to: file, options: .atomic)
        }
        return runs
    }
}
