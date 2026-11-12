import Dictionary
import Foundation

/// Field values in the formats Yomitan writes, so mined cards look like
/// existing Lapis cards.
public enum CardFormatting {
    /// Anki's bracket furigana: 食[た]べる, お 茶[ちゃ]. A space separates a kanji run
    /// from the text before it so Anki knows where the ruby starts.
    public static func furigana(expression: String, reading: String) -> String {
        var result = ""
        for segment in Furigana.segments(expression: expression, reading: reading) {
            if let reading = segment.reading {
                result += (result.isEmpty ? "" : " ") + "\(segment.text)[\(reading)]"
            } else {
                result += segment.text
            }
        }
        return result
    }

    /// Yomitan's downstep notation, e.g. [0]; several accents become a list.
    public static func pitchPosition(downsteps: [Int]) -> String {
        let spans = downsteps.map {
            "<span class=\"pronunciation-downstep-notation\" data-downstep-position=\"\($0)\" style=\"display:inline;\">"
                + "<span class=\"pronunciation-downstep-notation-prefix\">[</span>"
                + "<span class=\"pronunciation-downstep-notation-number\">\($0)</span>"
                + "<span class=\"pronunciation-downstep-notation-suffix\">]</span></span>"
        }
        if spans.count <= 1 { return spans.first ?? "" }
        return "<ol>" + spans.map { "<li>\($0)</li>" }.joined() + "</ol>"
    }

    /// Yomitan's pitch categories (heiban, atamadaka, nakadaka, odaka, kifuku), comma-separated.
    /// Verbs and i-adjectives with a drop are kifuku. A する-noun (勉強, rule vs) is a noun here,
    /// as in Yomitan; only a headword ending in する counts as the verb.
    public static func pitchCategories(downsteps: [Int], expression: String, reading: String, rules: [String]) -> String {
        let moraCount = Mora.split(reading).count
        let inflecting = rules.contains { rule in
            rule == "vs" ? expression.hasSuffix("する") : (rule.hasPrefix("v") || rule == "adj-i")
        }
        var categories: [String] = []
        for downstep in downsteps {
            let category: String
            if downstep == 0 {
                category = "heiban"
            } else if inflecting {
                category = "kifuku"
            } else if downstep == 1 {
                category = "atamadaka"
            } else if downstep == moraCount {
                category = "odaka"
            } else {
                category = "nakadaka"
            }
            if !categories.contains(category) { categories.append(category) }
        }
        return categories.joined(separator: ",")
    }

    public static func frequencyList(_ groups: [FrequencyGroup]) -> String {
        let items = groups.flatMap { group in
            group.values.map { "<li data-dictionary=\"\(escape(group.dictionary))\">\(escape(group.dictionary)): \(escape($0.display))</li>" }
        }
        return items.isEmpty ? "" : "<ul data-content=\"frequencies\">" + items.joined() + "</ul>"
    }

    /// Yomitan's `{frequency-harmonic-rank}`, which Lapis sorts by: the harmonic mean of each
    /// dictionary's best (lowest) rank, or 9999999 without frequency data.
    public static func frequencySort(_ groups: [FrequencyGroup]) -> String {
        let ranks = groups.compactMap { $0.values.map(\.value).filter { $0 > 0 }.min() }
        guard !ranks.isEmpty else { return "9999999" }
        let mean = Double(ranks.count) / ranks.reduce(0) { $0 + 1 / Double($1) }
        return String(Int(mean))
    }

    /// The sentence with the first occurrence of the mined word in bold.
    public static func boldedSentence(_ sentence: String, match: String) -> String {
        guard !match.isEmpty, let range = sentence.range(of: match) else { return escape(sentence) }
        return escape(String(sentence[..<range.lowerBound])) + "<b>" + escape(match) + "</b>" + escape(String(sentence[range.upperBound...]))
    }

    public struct GlossaryItem: Equatable, Sendable {
        public var dictionary: String
        public var tags: [String]
        /// Rendered definition HTML.
        public var html: String

        public init(dictionary: String, tags: [String], html: String) {
            self.dictionary = dictionary
            self.tags = tags
            self.html = html
        }
    }

    /// Yomitan's glossary markup: one list item per definition, labelled with its tags and dictionary.
    public static func glossary(_ items: [GlossaryItem]) -> String {
        guard !items.isEmpty else { return "" }
        let list = items.map { item -> String in
            let label = (item.tags + [item.dictionary]).map(escape).joined(separator: ", ")
            return "<li data-dictionary=\"\(escape(item.dictionary))\"><i>(\(label))</i> \(item.html)</li>"
        }.joined()
        return "<div style=\"text-align: left;\" class=\"yomitan-glossary\"><ol>\(list)</ol></div>"
    }

    /// A glanceable definition: the first senses, each with its first glosses, one line per
    /// sense ("1. rich; strong; heavy"). Parenthetical notes are dropped unless they're the whole
    /// gloss, and repeated glosses are skipped.
    public static func shortDefinition(_ senses: [[String]], maxSenses: Int = 3, maxGlosses: Int = 3) -> String {
        var seen = Set<String>()
        let lines = senses.compactMap { sense -> String? in
            let glosses = sense.map(withoutNotes).filter { !$0.isEmpty && seen.insert($0).inserted }.prefix(maxGlosses)
            return glosses.isEmpty ? nil : glosses.map(escape).joined(separator: "; ")
        }.prefix(maxSenses)
        if lines.count <= 1 { return lines.first ?? "" }
        return lines.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "<br>")
    }

    private static func withoutNotes(_ gloss: String) -> String {
        let stripped = gloss.replacingOccurrences(of: #"\s*[(（][^()（）]*[)）]\s*"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return stripped.isEmpty ? gloss.trimmingCharacters(in: .whitespaces) : stripped
    }

    public static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
