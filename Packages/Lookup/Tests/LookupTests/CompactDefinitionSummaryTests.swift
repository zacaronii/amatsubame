import Dictionary
import Foundation
@testable import Lookup
import Testing

/// The port of Hachidori's compact definition summary. Checked against Hachidori's own
/// JavaScript on 357 real lookups (RealCompactSummaryTests); these pin the main rules.
@Suite struct CompactDefinitionSummaryTests {
    func glossary(_ dictionary: String, _ value: Any) -> Glossary {
        let data = try! JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed)
        return Glossary(dictionary: dictionary, json: String(data: data, encoding: .utf8)!, definitionTags: [])
    }

    /// Jitendex marks its glossary lists; parts of speech and examples are left out.
    @Test func jitendexGlossaryListsWin() {
        let content: [String: Any] = ["type": "structured-content", "content": [
            ["tag": "span", "data": ["content": "part-of-speech-info"], "content": "adjectival"],
            ["tag": "ul", "data": ["content": "glossary"], "content": [
                ["tag": "li", "content": "guilt-free"], ["tag": "li", "content": "sinless"], ["tag": "li", "content": "innocent"],
                ["tag": "li", "content": "blameless"],
            ]],
            ["tag": "div", "data": ["content": "example-sentence"], "content": "罪なき人々を守る"],
        ]]
        let summary = CompactDefinitionSummary.extract([glossary("Jitendex", [content])])
        #expect(summary?.items == ["guilt-free", "sinless", "innocent"])
        #expect(CompactDefinitionSummary.extract([glossary("Jitendex", [content])], maximumItems: 1)?.items == ["guilt-free"])
        #expect(CompactDefinitionSummary.extract([glossary("Jitendex", [content])], maximumItems: 9)?.items.count == 3, "out of range: 3")
    }

    @Test func plainDefinitionsSplitOnBulletsAndSkipDuplicates() {
        let summary = CompactDefinitionSummary.extract([glossary("JMdict", ["to eat • to live on", "to eat"])])
        #expect(summary?.items == ["to eat", "to live on"])
    }

    @Test func thePreferredDictionaryGoesFirst() {
        let glossaries = [glossary("A", ["first"]), glossary("B", ["second"])]
        #expect(CompactDefinitionSummary.extract(glossaries)?.dictionary == "A")
        #expect(CompactDefinitionSummary.extract(glossaries, preferredDictionary: "B")?.items == ["second"])
        #expect(CompactDefinitionSummary.extract(glossaries, preferredDictionary: "C")?.dictionary == "A")
    }

    @Test func snippetsStopAt240Characters() {
        let long = String(repeating: "あ", count: 300)
        let summary = CompactDefinitionSummary.extract([glossary("A", [long, "more"])])
        #expect(summary?.items.count == 1)
        #expect(summary?.items.first?.count == 240 && summary?.items.first?.hasSuffix("…") == true)
    }

    @Test func aLeadingImageBecomesTheThumbnail() {
        let content: [String: Any] = ["type": "structured-content", "content": [["tag": "img", "path": "img/cat.png"], "a cat"]]
        let summary = CompactDefinitionSummary.extract([glossary("Pictures", [content])])
        #expect(summary?.imagePath == "img/cat.png" && summary?.items == ["a cat"])
        #expect(CompactDefinitionSummary.extract([glossary("A", [""])]) == nil)
    }

    @Test func theSummarySitsBesideTheHeadword() {
        let result = TermLookupResult(matched: "猫", deinflected: "猫", expression: "猫", reading: "ねこ",
                                      glossaries: [glossary("JMdict", ["cat • puss"])])
        let html = EntryRenderer.entries([result], summary: .init())
        #expect(html.contains(#"</span><div class="compact-summary" data-dictionary="JMdict"><ul class="compact-summary-items"><li>cat</li><li>puss</li></ul></div>"#))
        #expect(!EntryRenderer.entries([result]).contains("compact-summary"))
    }
}
