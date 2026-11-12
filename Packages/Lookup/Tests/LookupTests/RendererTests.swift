import Dictionary
import Foundation
@testable import Lookup
import Testing

@Suite struct StructuredContentRendererTests {
    let renderer = StructuredContentRenderer(dictionary: "Jitendex")

    func json(_ value: Any) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), encoding: .utf8)!
    }

    @Test func plainStringDefinitionsAreEscaped() {
        #expect(renderer.render(glossaryJSON: json(["a <b> & c"])) == #"<div class="gloss-content">a &lt;b&gt; &amp; c</div>"#)
    }

    @Test func severalDefinitionsBecomeAList() {
        let html = renderer.render(glossaryJSON: json(["one", ["type": "text", "text": "two"]]))
        #expect(html.hasPrefix(#"<ol class="gloss-list">"#))
        #expect(html.contains(#"<li class="gloss-item"><div class="gloss-content">one</div></li>"#))
        #expect(html.contains(">two<"))
    }

    @Test func jitendexShapedContentKeepsDataAttributesForItsCSS() {
        let content: [String: Any] = [
            "type": "structured-content",
            "content": [
                "tag": "ul", "lang": "ja", "data": ["content": "sense-groups"],
                "content": ["tag": "li", "data": ["content": "sense-group"], "content": [
                    ["tag": "span", "title": "Ichidan verb", "data": ["class": "tag", "code": "v1", "content": "part-of-speech-info"], "content": "1-dan"],
                    ["tag": "ul", "data": ["content": "glossary"], "content": [["tag": "li", "content": "to eat"]]],
                ]],
            ],
        ]
        let html = renderer.render(glossaryJSON: json([content]))
        #expect(html.contains(#"<ul class="gloss-sc-ul" lang="ja" data-sc-content="sense-groups">"#))
        #expect(html.contains(#"<span class="gloss-sc-span" data-sc-class="tag" data-sc-code="v1" data-sc-content="part-of-speech-info" title="Ichidan verb">1-dan</span>"#))
        #expect(html.contains(#"<li class="gloss-sc-li">to eat</li>"#))
    }

    /// Glossary lists only (no examples or references), one per sense, with ruby readings dropped.
    @Test func glossesComeFromGlossaryListsOrPlainStrings() {
        let sense: (String) -> [String: Any] = { gloss in
            ["tag": "li", "data": ["content": "sense"], "content": [
                ["tag": "ul", "data": ["content": "glossary"], "content": [
                    ["tag": "li", "content": gloss], ["tag": "li", "content": ["see ", ["tag": "ruby", "content": ["漢", ["tag": "rt", "content": "かん"]]]]],
                ]],
                ["tag": "ul", "data": ["content": "examples"], "content": [["tag": "li", "content": "例文"]]],
            ]]
        }
        let jitendex = json([["type": "structured-content", "content": ["tag": "ol", "content": [sense("to eat"), sense("to live on")]]]])
        #expect(StructuredContentRenderer.glosses(glossaryJSON: jitendex) == [["to eat", "see 漢"], ["to live on", "see 漢"]])
        #expect(StructuredContentRenderer.glosses(glossaryJSON: json(["desperate", " frantic "])) == [["desperate", "frantic"]])
        let prose = json([["type": "structured-content", "content": ["けす【消す】", ["tag": "br"], "put out"]]])
        #expect(StructuredContentRenderer.glosses(glossaryJSON: prose).isEmpty)
    }

    @Test func camelCaseDataKeysBecomeKebabAttributes() {
        let html = renderer.content(["tag": "div", "data": ["someKey": "x"], "content": "y"])
        #expect(html == #"<div class="gloss-sc-div" data-sc-some-key="x">y</div>"#)
    }

    @Test func stylesFollowYomitansRules() {
        let html = renderer.content(["tag": "span", "style": [
            "fontWeight": "bold", "marginTop": 0.5, "marginLeft": "2px", "textDecorationLine": ["underline", "overline"],
            "unsupported": "ignored",
        ], "content": "x"])
        #expect(html.contains("font-weight: bold"))
        #expect(html.contains("margin-top: 0.5em"))
        #expect(html.contains("margin-left: 2px"))
        #expect(html.contains("text-decoration: underline overline"))
        #expect(!html.contains("unsupported"))
    }

    @Test func rubyBreaksAndTables() {
        #expect(renderer.content(["tag": "ruby", "content": ["漢", ["tag": "rt", "content": "かん"]]])
            == #"<ruby class="gloss-sc-ruby">漢<rt class="gloss-sc-rt">かん</rt></ruby>"#)
        #expect(renderer.content(["tag": "br"]) == #"<br class="gloss-sc-br">"#)
        let table = renderer.content(["tag": "table", "content": ["tag": "tr", "content": ["tag": "td", "colSpan": 2, "content": "x"]]])
        #expect(table.hasPrefix(#"<div class="gloss-sc-table-container"><table class="gloss-sc-table">"#))
        #expect(table.contains(#"<td class="gloss-sc-td" colspan="2">x</td>"#))
    }

    @Test func internalLinksBecomeLookupsExternalLinksStayLinks() {
        let lookupLink = renderer.content(["tag": "a", "href": "?query=%E9%A3%9F%E3%81%B9%E3%82%8B&wildcards=off", "content": "食べる"])
        #expect(lookupLink.contains(#"data-lookup="食べる""#))
        #expect(lookupLink.contains(#"data-external="false""#))
        #expect(!lookupLink.contains("href"))
        let external = renderer.content(["tag": "a", "href": "https://example.com/a?b=1&c=2", "content": "site"])
        #expect(external.contains(#"href="https://example.com/a?b=1&amp;c=2""#))
        #expect(external.contains(#"data-external="true""#))
    }

    @Test func imagesLoadFromDictionaryMedia() {
        let html = renderer.content(["tag": "img", "path": "jitendex/HanaMinA/074e4.svg", "width": 1, "height": 1,
                                     "sizeUnits": "em", "verticalAlign": "middle", "title": "glyph"])
        #expect(html.contains(#"src="dictmedia://media/jitendex/HanaMinA/074e4.svg?dictionary=Jitendex""#))
        #expect(html.contains("width: 1em"))
        #expect(html.contains(#"class="gloss-image-container""#))
        #expect(html.contains(#"title="glyph""#))
    }

    @Test func malformedJSONIsShownAsText() {
        #expect(renderer.render(glossaryJSON: "not json <x>").contains("not json &lt;x&gt;"))
    }
}

@Suite struct EntryRendererTests {
    let result = TermLookupResult(
        matched: "食べさせられなかった", deinflected: "食べる", expression: "食べる", reading: "たべる",
        inflections: [Inflection(name: "causative"), Inflection(name: "negative")],
        glossaries: [Glossary(dictionary: "Jitendex", json: #"["to eat"]"#, definitionTags: ["★"])],
        frequencies: [FrequencyGroup(dictionary: "JPDB", values: [Frequency(value: 184, display: "184"), Frequency(value: 13390, display: "13390㋕")])],
        pitches: [PitchGroup(dictionary: "Kanjium", accents: [PitchAccent(downstep: 2)])]
    )

    @Test func entryHasFuriganaInflectionsFrequencyPitchAndGlossary() {
        let html = EntryRenderer.entries([result])
        #expect(html.contains("<ruby>食<rt>た</rt></ruby>べる"))
        #expect(html.contains(#"<span class="inflection" title="">causative</span><span class="inflection-separator">«</span><span class="inflection" title="">negative</span>"#))
        #expect(html.contains(#"<span class="frequency-value">184 / 13390㋕</span>"#))
        #expect(html.contains(#"data-pattern="nakadaka""#))
        #expect(html.contains(#"<span class="mora high downstep">べ</span>"#))
        #expect(html.contains(#"<span class="pitch-number">[2]</span>"#))
        #expect(html.contains(#"<section class="glossary" data-dictionary="Jitendex">"#))
        #expect(html.contains(#"data-action="audio" data-index="0""#))
    }

    @Test func emptyResultsSayNoResults() {
        #expect(EntryRenderer.entries([]).contains("No results"))
    }

    @Test func documentScopesDictionaryCSSAndIncludesBridge() {
        let html = LookupPage.document(body: "<p>x</p>", dictionaryStyles: ["Jitendex \"x\"": "span { color: red; }"])
        #expect(html.contains(#"[data-dictionary="Jitendex \"x\""] {"#))
        #expect(html.contains("span { color: red; }"))
        #expect(html.contains("messageHandlers?.lookup"))
        #expect(html.contains("--font-size-no-units: 16"))
    }
}

@Suite struct SourceHeaderTests {
    @Test func highlightsTheMatchedSpan() {
        let html = EntryRenderer.source(LookupSource(text: "今日は<映画>を見た", utf16Offset: 4, utf16Length: 2))
        #expect(html == #"<div class="source" lang="ja">今日は&lt;<mark>映画</mark>&gt;を見た</div>"#)
    }

    @Test func outOfRangeOffsetsAreClamped() {
        let html = EntryRenderer.source(LookupSource(text: "あい", utf16Offset: 5, utf16Length: 3))
        #expect(html == #"<div class="source" lang="ja">あい<mark></mark></div>"#)
    }
}

@Suite struct PopupEntryTests {
    static let examples = #"[{"type":"structured-content","content":[{"tag":"ul","data":{"content":"glossary"},"content":[{"tag":"li","content":"why?"}]},{"tag":"ul","lang":"ja","data":{"content":"examples"},"content":[{"tag":"li","content":"ここになんで来たの？"},{"tag":"li","lang":"en","content":"Why did you come here?"}]}]}]"#

    static let nande = TermLookupResult(
        matched: "なんで", deinflected: "なんで", expression: "何で", reading: "なんで", rules: [],
        glossaries: [
            Glossary(dictionary: "JMdict [2025-11-01]", json: examples, definitionTags: ["1", "adv"]),
            Glossary(dictionary: "JMdict [2025-11-01]", json: #"["how?"]"#, definitionTags: ["2", "adv"]),
        ],
        frequencies: [], pitches: []
    )

    @Test func dictionaryNameShowsOnceWithoutItsDate() {
        let html = EntryRenderer.entries([Self.nande])
        #expect(html.components(separatedBy: #"<div class="dictionary-name">"#).count == 2)
        #expect(html.contains("</svg>JMdict</div>") && !html.contains("2025-11-01</"))
        #expect(EntryRenderer.displayName("KANJIDIC [2025-345]") == "KANJIDIC" && EntryRenderer.displayName("[x]") == "[x]")
    }

    @Test func senseNumbersAreCircles() {
        #expect(EntryRenderer.tag("2") == #"<span class="sense-number">2</span>"#)
        #expect(EntryRenderer.tag("adv") == #"<span class="tag">adv</span>"#)
    }

    @Test func theWordIsMarkedInJapaneseExamplesOnly() {
        let html = EntryRenderer.entries([Self.nande])
        #expect(html.contains(#"ここに<span class="example-word">なんで</span>来たの？"#))
        #expect(html.contains(">Why did you come here?<"))
    }

    @Test func headwordFuriganaIsRuby() {
        #expect(EntryRenderer.headword(Self.nande) == "<ruby>何<rt>なん</rt></ruby>で")
    }
}
