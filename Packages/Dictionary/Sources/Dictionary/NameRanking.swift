import Foundation

/// Like Yomitan and hoshidicts, the engine ranks the longest match first, and it always tries
/// hiragana as katakana. So tapping た in 「たと思う」 opened JMnedict's name タト before た.
/// For taps in text, a name that matched only through that conversion goes below the rest
/// (10ten Japanese Reader treats such kana-only name matches as likely false positives).
/// Typed searches keep the engine's order, so 「まさと」 still finds マサト first.
nonisolated public enum NameRanking {
    /// The character names dictionary's title (Packages/Names: the casts of the open series).
    public static let characterNamesTitle = "Character Names"
    /// Name dictionaries, by title.
    public static let namePrefixes = ["JMnedict", characterNamesTitle]

    /// A local lookup's character names: each result with only that dictionary's glossaries (a
    /// name spelled like a word shares the word's result).
    public static func characterNames(in results: [TermLookupResult]) -> [TermLookupResult] {
        results.compactMap { result in
            var name = result
            name.glossaries = result.glossaries.filter { $0.dictionary == characterNamesTitle }
            // The word's frequency and pitch aren't the name's.
            if name.glossaries.count < result.glossaries.count {
                name.frequencies = []
                name.pitches = []
            }
            return name.glossaries.isEmpty ? nil : name
        }
    }

    /// The Mac looks words up on a linked Hachidori host, which doesn't have the names of the
    /// series open here: the local names' hits join its results before every one as long or
    /// shorter (the open series' names win a tie, as locally: `characterNamesFirst`).
    public static func merging(names: [TermLookupResult], into results: [TermLookupResult]) -> [TermLookupResult] {
        var merged = results
        for name in names.reversed() {
            let length = name.matched.count
            let position = merged.firstIndex { $0.matched.count <= length } ?? merged.endIndex
            merged.insert(name, at: position)
        }
        return merged
    }

    /// The open series' characters first among matches of the same length: the reader is in that
    /// series, so a name there is almost always who's meant (アイゼン before a word spelled the
    /// same). A longer match still comes first, and a name matched through hiragana it isn't
    /// written with (its reading, or hiragana read as katakana) isn't moved up: ゆき in prose is
    /// still 雪 before a character called ユキ.
    public static func characterNamesFirst(_ results: [TermLookupResult]) -> [TermLookupResult] {
        var ranked: [TermLookupResult] = []
        var run: [TermLookupResult] = []
        func flush() {
            ranked += run.filter(isOpenSeriesName) + run.filter { !isOpenSeriesName($0) }
            run = []
        }
        for result in results {
            if let last = run.last, last.matched.count != result.matched.count { flush() }
            run.append(result)
        }
        flush()
        return ranked
    }

    static func isOpenSeriesName(_ result: TermLookupResult) -> Bool {
        result.glossaries.contains { $0.dictionary == characterNamesTitle }
            && (!hasHiragana(result.matched) || hasHiragana(result.expression))
    }

    public static func forTextTap(_ results: [TermLookupResult]) -> [TermLookupResult] {
        let results = characterNamesFirst(results)
        let demoted = results.filter(isConvertedName)
        guard !demoted.isEmpty, demoted.count < results.count else { return results }
        return results.filter { !isConvertedName($0) } + demoted
    }

    /// Only names (every glossary from a name dictionary), matched as hiragana against an
    /// entry written without any.
    static func isConvertedName(_ result: TermLookupResult) -> Bool {
        guard result.preprocessorSteps > 0, !result.glossaries.isEmpty,
              result.glossaries.allSatisfy({ glossary in namePrefixes.contains { glossary.dictionary.hasPrefix($0) } }) else {
            return false
        }
        return hasHiragana(result.matched) && !hasHiragana(result.expression) && !hasHiragana(result.reading)
    }

    static func hasHiragana(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x3041...0x3096).contains($0.value) }
    }
}
