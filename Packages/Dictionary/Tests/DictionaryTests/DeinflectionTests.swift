import Dictionary
import DictionaryTestSupport
import Foundation
import Testing

/// Yomitan's Japanese transform test cases, run end to end through hoshidicts:
/// a dictionary holding only the base terms, then a lookup of each inflected form.
@Suite(.serialized) struct DeinflectionTests {
    static let fixture = try! TransformFixture.load()

    static func makeEngine() async throws -> DictionaryEngine {
        var builder = TestDictionaryBuilder(title: "Transforms")
        builder.terms = fixture.terms.map { term, rule in
            TestDictionaryBuilder.Term(term, term, rules: rule, glossary: ["\(term) (\(rule))"])
        }
        let library = try makeLibrary()
        try await library.importDictionary(at: try builder.write())
        return library.engine
    }

    @Test func tabesaserarenakattaFindsTaberu() async throws {
        let engine = try await Self.makeEngine()
        let result = try #require(await engine.lookup("食べさせられなかった").first)
        #expect(result.expression == "食べる")
        #expect(result.matched == "食べさせられなかった")
        #expect(result.inflections.map(\.name) == ["causative", "potential or passive", "negative", "-た"])
    }

    /// Where hoshidicts (Yomitan's rules as ported, upstream e6af33e) differs from current Yomitan.
    /// Each group is a known issue: if hoshidicts gains the rules, the test reports the group as fixed.
    enum KnownDifference: String, CaseIterable {
        case historicalKana = "Historical kana spellings (さう, ませう, やう, ゐる, 思ふ…) aren't in hoshidicts' rules"
        case yashinai = "-やしない / -やしません aren't in hoshidicts' rules"
        case singleCharacter = "hoshidicts doesn't deinflect one-character text (し → する)"
        case traceLabel = "Right word, different trace (来られる 'passive' vs 'potential or passive'; っちゃ via -ば -ゃ)"

        static func classify(source: String, term: String, wrongTraceOnly: Bool) -> KnownDifference? {
            if wrongTraceOnly {
                let traceCases: Set<String> = ["行きゃ", "待っちゃ", "来られる", "来られない", "來られる", "來られない",
                                               "こられる", "こられない", "やんなきゃ"]
                return traceCases.contains(source) ? .traceLabel : nil
            }
            if source.count == 1 { return .singleCharacter }
            if source.contains("やしな") || source.contains("やしま") || source.contains("やしね") { return .yashinai }
            let historical = /ゐ|ゑ|さう$|ませう|やう$|からう$|[かがさたなはばまらわ]う$|思[はひふへ]|しま[はひふへ]/
            return source.contains(historical) ? .historicalKana : nil
        }
    }

    @Test func yomitanTransformCases() async throws {
        let engine = try await Self.makeEngine()
        var known: [KnownDifference: [String]] = [:]
        var unexplained: [String] = []
        var falsePositives: [String] = []
        var found = 0
        for testCase in Self.fixture.cases {
            let results = await engine.lookup(testCase.source, maxResults: 64)
            let matches = results.filter { $0.expression == testCase.term && $0.matched == testCase.source }
            let traces = matches.map { $0.inflections.map(\.name) }
            let label = "\(testCase.category): \(testCase.source) → \(testCase.term) \(testCase.reasons ?? []) got \(traces)"
            if testCase.valid {
                if !matches.isEmpty { found += 1 }
                let wrongTrace = !matches.isEmpty && testCase.reasons.map { !traces.contains($0) } == true
                guard matches.isEmpty || wrongTrace else { continue }
                if let difference = KnownDifference.classify(source: testCase.source, term: testCase.term, wrongTraceOnly: wrongTrace) {
                    known[difference, default: []].append(label)
                } else {
                    unexplained.append(label)
                }
            } else if let reasons = testCase.reasons {
                if traces.contains(reasons) { falsePositives.append(label) }
            } else if !matches.isEmpty {
                falsePositives.append(label)
            }
        }
        let valid = Self.fixture.cases.filter(\.valid).count
        print("Yomitan cases: \(Self.fixture.cases.count); valid \(valid), word found \(found); "
              + KnownDifference.allCases.map { "\($0): \(known[$0]?.count ?? 0)" }.joined(separator: ", "))

        #expect(unexplained.isEmpty, "Mismatches not covered by a known difference")
        #expect(falsePositives.isEmpty, "Invalid forms that deinflected anyway")
        for difference in KnownDifference.allCases {
            withKnownIssue(Comment(rawValue: difference.rawValue)) {
                #expect((known[difference] ?? []).isEmpty)
            }
        }
    }
}
