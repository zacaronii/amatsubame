import Foundation

/// Search in a book: the text as the reader shows it (`BookTextCollector`'s runs), matched in
/// any case, full or half width, and hiragana for katakana. Each hit knows its run and where in
/// it the match is (UTF-16, as the page's script counts), with a little text either side.
public enum BookSearch {
    /// Results stop here (the sheet says so).
    public static let limit = 500
    /// Characters of context either side of a match.
    static let context = 20

    public struct Hit: Equatable, Sendable, Identifiable {
        public var section: Int
        public var run: Int
        /// The match in the run's text, in UTF-16 units.
        public var offset: Int
        public var length: Int
        public var before: String
        public var match: String
        public var after: String

        public var id: String { "\(section)-\(run)-\(offset)" }
    }

    public static func hits(_ query: String, in runs: [BookTextRun], limit: Int = limit) -> [Hit] {
        let needle = units(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !needle.isEmpty else { return [] }
        var hits: [Hit] = []
        for run in runs {
            let characters = Array(run.text)
            let folded = characters.map(fold)
            guard folded.count >= needle.count else { continue }
            var index = 0
            while index + needle.count <= folded.count {
                if folded[index] == needle[0], Array(folded[index..<(index + needle.count)]) == needle {
                    let end = index + needle.count
                    let offset = String(characters[..<index]).utf16.count
                    let match = String(characters[index..<end])
                    hits.append(Hit(section: run.section, run: run.run, offset: offset, length: match.utf16.count,
                                    before: String(characters[max(index - context, 0)..<index]), match: match,
                                    after: String(characters[end..<min(end + context, characters.count)])))
                    if hits.count >= limit { return hits }
                    index = end
                } else {
                    index += 1
                }
            }
        }
        return hits
    }

    private static func units(_ text: String) -> [String] { Array(text).map(fold) }

    /// One character as compared: case and width folded, hiragana as katakana.
    static func fold(_ character: Character) -> String {
        let folded = String(character).folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)
        return folded.applyingTransform(.hiraganaToKatakana, reverse: false) ?? folded
    }
}
