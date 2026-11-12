import Foundation

/// Turns "the user tapped character N of this text" into what to look up and
/// the sentence it came from. Offsets are UTF-16, matching what WebKit's
/// `caretRangeFromPoint` and NSString ranges report.
public enum TextScanner {
    static let sentenceEnders: Set<Character> = ["。", "！", "？", "!", "?", "．", "…", "\n"]
    static let closingQuotes: Set<Character> = ["」", "』", "）", ")", "】", "〉", "》", "”", "’"]

    /// The text from the tapped character forward, up to `maxLength` characters,
    /// stopping at a line break. Leading whitespace isn't scanned.
    public static func scanText(_ text: String, utf16Offset: Int, maxLength: Int = 32) -> String {
        guard let start = index(in: text, utf16Offset: utf16Offset) else { return "" }
        var scanned = ""
        for character in text[start...] {
            if character.isNewline || scanned.count >= maxLength { break }
            scanned.append(character)
        }
        return scanned
    }

    /// The sentence containing the tapped character, trimmed, with a closing quote kept
    /// when the sentence ends inside one (「…。」).
    public static func sentence(in text: String, utf16Offset: Int) -> String {
        guard let tap = index(in: text, utf16Offset: utf16Offset) else { return "" }
        var start = tap
        while start > text.startIndex {
            let previous = text.index(before: start)
            if sentenceEnders.contains(text[previous]) { break }
            start = previous
        }
        // A closing quote right after the previous sentence's 。 belongs to that sentence.
        while start < tap, closingQuotes.contains(text[start]) {
            start = text.index(after: start)
        }
        var end = tap
        while end < text.endIndex {
            let character = text[end]
            end = text.index(after: end)
            if sentenceEnders.contains(character) {
                if character.isNewline { end = text.index(before: end) }
                break
            }
        }
        while end < text.endIndex, closingQuotes.contains(text[end]) {
            end = text.index(after: end)
        }
        return String(text[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Every sentence of `text` as UTF-16 ranges, by the same rules as `sentence(in:utf16Offset:)`
    /// (enders, a closing quote kept with the sentence it ends), leading and trailing space left
    /// out and empty ones skipped. Read-along splits a book's text with this.
    public static func sentences(in text: String) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var start = text.startIndex
        var index = text.startIndex
        func add(_ end: String.Index) {
            var from = start, to = end
            while from < to, text[from].isWhitespace { from = text.index(after: from) }
            while to > from, text[text.index(before: to)].isWhitespace { to = text.index(before: to) }
            if from < to {
                ranges.append(from.utf16Offset(in: text)..<to.utf16Offset(in: text))
            }
        }
        while index < text.endIndex {
            let character = text[index]
            index = text.index(after: index)
            guard sentenceEnders.contains(character) else { continue }
            // "……" and "！？" end once; a closing quote after the ender stays with it.
            while index < text.endIndex, sentenceEnders.contains(text[index]), !text[index].isNewline { index = text.index(after: index) }
            while index < text.endIndex, closingQuotes.contains(text[index]) { index = text.index(after: index) }
            add(index)
            start = index
        }
        add(text.endIndex)
        return ranges
    }

    private static func index(in text: String, utf16Offset: Int) -> String.Index? {
        guard utf16Offset >= 0, utf16Offset < text.utf16.count else { return nil }
        // Snap to the start of the character containing this code unit; taps can land
        // in the middle of a surrogate pair or a combining sequence.
        let range = (text as NSString).rangeOfComposedCharacterSequence(at: utf16Offset)
        return Range(range, in: text)?.lowerBound
    }
}
