@testable import Dictionary
import Testing

struct NameRankingTests {
    func result(_ matched: String, _ expression: String, _ reading: String, steps: Int = 0, from dictionaries: [String]) -> TermLookupResult {
        TermLookupResult(matched: matched, deinflected: matched, expression: expression, reading: reading,
                         preprocessorSteps: steps, glossaries: dictionaries.map { Glossary(dictionary: $0, json: "[]") })
    }

    /// 「たと思う」: the engine ranks the longer match, JMnedict's タト (via hiragana → katakana), first.
    @Test func aConvertedNameGoesBelowWords() {
        let tato = result("たと", "タト", "タト", steps: 1, from: ["JMnedict [2026-11-11]"])
        let ta = result("た", "た", "た", from: ["Jitendex.org [2026-10-03]"])
        let field = result("た", "田", "た", from: ["Jitendex.org [2026-10-03]"])
        #expect(NameRanking.forTextTap([tato, ta, field]).map(\.expression) == ["た", "田", "タト"])
    }

    @Test func otherResultsKeepTheirOrder() {
        // A katakana word typed in hiragana (not a name dictionary).
        let tv = result("てれび", "テレビ", "テレビ", steps: 1, from: ["Jitendex.org [2026-10-03]"])
        let tere = result("てれ", "照れ", "てれ", from: ["Jitendex.org [2026-10-03]"])
        #expect(NameRanking.forTextTap([tv, tere]).map(\.expression) == ["テレビ", "照れ"])
        // A name written in kanji in the text, and one in both a name and a word dictionary.
        let tanaka = result("田中", "田中", "たなか", from: ["JMnedict [2026-11-11]"])
        let teru = result("てる", "てる", "てる", steps: 1, from: ["Jitendex.org [2026-10-03]", "JMnedict [2026-11-11]"])
        let ta = result("田", "田", "た", from: ["Jitendex.org [2026-10-03]"])
        #expect(NameRanking.forTextTap([tanaka, teru, ta]).map(\.expression) == ["田中", "てる", "田"])
    }

    /// The open series' characters come first among matches of the same length; a longer
    /// match still leads, and a name matched by hiragana it isn't written with isn't moved up.
    @Test func characterNamesLeadTheirLength() {
        let eisen = result("アイゼン", "アイゼン", "あいぜん", from: ["Character Names"])
        let word = result("アイゼン", "アイゼン", "アイゼン", from: ["Jitendex.org [2026-10-03]"])
        let longer = result("アイゼンは", "アイゼンハワー", "あいぜんはわー", from: ["JMnedict [2026-11-11]"])
        let shorter = result("アイ", "愛", "あい", from: ["Jitendex.org [2026-10-03]"])
        #expect(NameRanking.forTextTap([longer, word, eisen, shorter]).map { $0.glossaries[0].dictionary.prefix(4) }
            == ["JMne", "Char", "Jite", "Jite"])
        // Matched by its reading in hiragana (ゆき in prose): the word stays first.
        let yuki = result("ゆき", "ユキ", "ゆき", from: ["Character Names"])
        let snow = result("ゆき", "雪", "ゆき", from: ["Jitendex.org [2026-10-03]"])
        #expect(NameRanking.forTextTap([snow, yuki]).map(\.expression) == ["雪", "ユキ"])
        // A name written in hiragana is found as written, and leads.
        let hana = result("はな", "はな", "はな", from: ["Character Names"])
        let flower = result("はな", "花", "はな", from: ["Jitendex.org [2026-10-03]"])
        #expect(NameRanking.forTextTap([flower, hana]).map(\.expression) == ["はな", "花"])
    }

    /// On the Mac (linked to Hachidori), a local name joins the host's results before its same-length ones.
    @Test func mergedNamesLeadTheirLength() {
        let host = [result("映画", "映画", "えいが", from: ["Host"]), result("映", "映", "えい", from: ["Host"])]
        let name = result("映画", "映画", "えいが", from: ["Character Names"])
        #expect(NameRanking.merging(names: [name], into: host).map { $0.glossaries[0].dictionary } == ["Character Names", "Host", "Host"])
    }

    /// With nothing else to show, the name stays.
    @Test func onlyNamesStay() {
        let masato = result("まさと", "マサト", "マサト", steps: 1, from: ["JMnedict [2026-11-11]"])
        #expect(NameRanking.forTextTap([masato]).map(\.expression) == ["マサト"])
    }
}
