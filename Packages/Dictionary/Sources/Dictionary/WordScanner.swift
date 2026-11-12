import CHoshiDicts
import Foundation

/// One dictionary word in a line of text: where it is (UTF-16 offsets) and its dictionary form.
public struct WordSpan: Codable, Equatable, Hashable, Sendable {
    public var offset: Int
    public var length: Int
    /// The dictionary form (悪く → 悪い) and its reading, as the mining deck stores them.
    public var expression: String
    public var reading: String

    public init(offset: Int, length: Int, expression: String, reading: String) {
        self.offset = offset
        self.length = length
        self.expression = expression
        self.reading = reading
    }
}

/// Splits text into dictionary words for word marks: the longest match at each position,
/// deinflected, as a tap would find it. It has its own hoshidicts lookup, so scanning a
/// chapter in the background never delays a tap on `DictionaryEngine`.
///
/// Only words worth marking are returned: ones with kanji, and katakana words of two or more
/// characters. Lookups start only at kanji, katakana, or a hiragana prefix right before kanji
/// (お茶, ご飯), so kana-only grammar and particles cost nothing.
public actor WordScanner {
    private let deinflector = Deinflector()
    private var handles: QueryHandles?
    private var frequencySortTitle: String?

    public init() {}

    /// Loads the term (and frequency, for ordering) dictionaries the engine uses.
    public func configure(_ dictionaries: [EngineDictionary], frequencySortTitle: String?) {
        let query = hd_query_new()!
        for dictionary in dictionaries {
            let path = dictionary.folder.path(percentEncoded: false)
            if dictionary.hasTerms { hd_query_add_term_dict(query, path) }
            if dictionary.hasFrequencies { hd_query_add_freq_dict(query, path) }
        }
        handles = QueryHandles(query: query, deinflector: deinflector)
        self.frequencySortTitle = frequencySortTitle ?? dictionaries.first(where: \.hasFrequencies)?.title
    }

    /// Dictionaries are loaded: before that, `words(in:)` finds nothing, which mustn't be kept.
    public var isReady: Bool { handles != nil }

    public func words(in text: String) -> [WordSpan] {
        guard handles != nil else { return [] }
        let characters = Array(text)
        var spans: [WordSpan] = []
        var index = 0, utf16 = 0
        while index < characters.count {
            let character = characters[index]
            let startsWord = Self.hasKanji(character) || Self.isKatakana(character)
                || (Self.isHiragana(character) && index + 1 < characters.count && Self.hasKanji(characters[index + 1]))
            guard startsWord, let match = longestMatch(String(characters[index..<min(index + 12, characters.count)])) else {
                utf16 += character.utf16.count
                index += 1
                continue
            }
            let surface = Array(match.matched)
            let count = max(1, min(surface.count, characters.count - index))
            let length = characters[index..<index + count].reduce(0) { $0 + $1.utf16.count }
            if surface.contains(where: Self.hasKanji) || (surface.count >= 2 && surface.allSatisfy(Self.isKatakana)) {
                spans.append(WordSpan(offset: utf16, length: length, expression: match.expression, reading: match.reading))
            }
            utf16 += length
            index += count
        }
        return spans
    }

    /// The longest dictionary match at the start of `text`: matched surface, expression, reading.
    private func longestMatch(_ text: String) -> (matched: String, expression: String, reading: String)? {
        guard let lookup = handles?.lookup else { return nil }
        let sortTitle = frequencySortTitle
        return text.withCString { textPointer in
            (sortTitle ?? "").withCString { sortPointer in
                var options = hd_lookup_options(
                    frequency_dictionary: sortTitle == nil ? hd_str(ptr: nil, len: 0) : hd_str(ptr: sortPointer, len: strlen(sortPointer)),
                    frequency_order: Int32(HD_LOOKUP_FREQUENCY_ORDER_AUTO.rawValue),
                    primary_reading: hd_str(ptr: nil, len: 0)
                )
                var results: UnsafePointer<hd_lookup_result>?
                var count = 0
                guard let handle = hd_lookup_run_with_options(lookup, textPointer, 8, 12, &options, &results, &count), count > 0 else {
                    return nil
                }
                defer { hd_lookup_results_free(handle) }
                // Results are ordered by frequency; the first of the longest wins.
                var best = results![0]
                for index in 1..<count where results![index].matched.len > best.matched.len { best = results![index] }
                return (best.matched.string, best.term.expression.string, best.term.reading.string)
            }
        }
    }

    static func hasKanji(_ character: Character) -> Bool {
        character.unicodeScalars.contains { $0.properties.isIdeographic || $0 == "々" || $0 == "〆" || $0 == "ヶ" }
    }

    static func isKatakana(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { (0x30A1...0x30FA).contains($0.value) || $0 == "ー" || (0xFF66...0xFF9F).contains($0.value) }
    }

    static func isHiragana(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { (0x3041...0x3096).contains($0.value) }
    }
}
