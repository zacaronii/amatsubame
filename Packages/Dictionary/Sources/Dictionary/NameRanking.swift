import Foundation

/// Like Yomitan and hoshidicts, the engine ranks the longest match first, and it always tries
/// hiragana as katakana. So tapping た in 「たと思う」 opened JMnedict's name タト before た.
/// For taps in text, a name that matched only through that conversion goes below the rest
/// (10ten Japanese Reader treats such kana-only name matches as likely false positives).
/// Typed searches keep the engine's order, so 「まさと」 still finds マサト first.
nonisolated public enum NameRanking {
    /// Name dictionaries, by title.
    public static let namePrefixes = ["JMnedict"]

    public static func forTextTap(_ results: [TermLookupResult]) -> [TermLookupResult] {
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
