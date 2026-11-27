import Testing
@testable import Dictionary

struct RedirectsTests {
    /// Jitendex's 精いっぱい, as hoshidicts returns it (shortened).
    let redirect = Glossary(dictionary: "Jitendex.org [2026-10-03]", json: """
    [{"type":"structured-content","content":{"tag":"div","data":{"content":"redirect-glossary"},"content":["⟶",\
    {"tag":"a","href":"?query=%E7%B2%BE%E4%B8%80%E6%9D%AF&wildcards=off&primary_reading=%E3%81%9B%E3%81%84%E3%81%84%E3%81%A3%E3%81%B1%E3%81%84",\
    "content":"精一杯"}]}},["精一杯",["redirected from 精いっぱい"]]]
    """)
    let full = Glossary(dictionary: "Jitendex.org [2026-10-03]", json: #"["the best one can do"]"#)

    var found: [String: [TermLookupResult]] {
        ["精一杯": [TermLookupResult(matched: "精一杯", deinflected: "精一杯", expression: "精一杯", reading: "せいいっぱい", glossaries: [full]),
                TermLookupResult(matched: "精一", deinflected: "精一", expression: "精一", reading: "せいいち")]]
    }

    @Test func aRedirectShowsTheEntryItPointsTo() {
        let tapped = TermLookupResult(matched: "精いっぱい", deinflected: "精いっぱい", expression: "精いっぱい", reading: "せいいっぱい",
                                      glossaries: [redirect])
        let kanji = TermLookupResult(matched: "精", deinflected: "精", expression: "精", reading: "せい")
        let results = Redirects.follow([tapped, kanji], found: found)
        #expect(results.map(\.expression) == ["精一杯", "精"])
        #expect(results[0].matched == "精いっぱい")
        #expect(results[0].glossaries == [full])
        #expect(results[0].inflections.map(\.name) == ["redirected from 精いっぱい"])
    }

    @Test func anotherDictionarysDefinitionStaysAheadOfTheRedirect() {
        let other = Glossary(dictionary: "JMdict", json: #"["with all one's might"]"#)
        let tapped = TermLookupResult(matched: "精いっぱい", deinflected: "精いっぱい", expression: "精いっぱい", reading: "せいいっぱい",
                                      glossaries: [redirect, other])
        let results = Redirects.follow([tapped], found: found)
        #expect(results.map(\.expression) == ["精いっぱい", "精一杯"])
        #expect(results[0].glossaries == [other])
    }

    @Test func aRedirectWithNothingToFollowStays() {
        let tapped = TermLookupResult(matched: "精いっぱい", deinflected: "精いっぱい", expression: "精いっぱい", reading: "せいいっぱい",
                                      glossaries: [redirect])
        #expect(Redirects.terms(in: [tapped]) == ["精一杯"])
        #expect(Redirects.follow([tapped], found: [:]) == [tapped])
    }

    @Test func theLinkNamesTheReading() {
        #expect(Redirects.targets(redirect) == [Redirects.Target(term: "精一杯", reading: "せいいっぱい", rules: ["redirected from 精いっぱい"])])
        #expect(Redirects.targets(full).isEmpty)
    }

    /// Jitendex's なあ: the particle and a redirect to 七 (しち), merged into one result by hoshidicts.
    let naaRedirect = Glossary(dictionary: "Jitendex.org [2026-10-03]", json: """
    [{"type":"structured-content","content":{"tag":"div","data":{"content":"redirect-glossary"},"content":["⟶",\
    {"tag":"a","href":"?query=%E4%B8%83&wildcards=off&primary_reading=%E3%81%97%E3%81%A1","content":"七"}]}},\
    ["七",["redirected from なあ"]]]
    """)
    let particle = Glossary(dictionary: "Jitendex.org [2026-10-03]", json: #"["expressing emotion; seeking agreement"]"#)

    @Test func aWordWithItsOwnEntryStaysAheadOfItsRedirect() {
        let tapped = TermLookupResult(matched: "なあ", deinflected: "なあ", expression: "なあ", reading: "なあ",
                                      glossaries: [particle, naaRedirect])
        let na = TermLookupResult(matched: "な", deinflected: "な", expression: "な", reading: "な")
        let seven = TermLookupResult(matched: "七", deinflected: "七", expression: "七", reading: "しち", glossaries: [full])
        let nana = TermLookupResult(matched: "七", deinflected: "七", expression: "七", reading: "なな")
        let results = Redirects.follow([tapped, na], found: ["七": [seven, nana]])
        #expect(results.map { "\($0.expression)/\($0.reading)" } == ["なあ/なあ", "七/しち", "な/な"])
        #expect(results[0].glossaries == [particle])
        #expect(results[1].inflections.map(\.name) == ["redirected from なあ"])
    }
}
