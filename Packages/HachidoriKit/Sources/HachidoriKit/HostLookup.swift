import Dictionary
import Foundation

/// An `hd_lookup` reply: the host's results in hoshidicts' own structure (docs/hachidori.md
/// section 3), mapped onto the results our local engine returns, so the popup draws both alike.
public struct HostLookupPage: Equatable, Sendable {
    public var results: [TermLookupResult]
    /// The host engine's generation: `hd_media` needs it for this page's images.
    public var generation: Int
    public var dictionaryCount: Int

    public init(results: [TermLookupResult], generation: Int, dictionaryCount: Int) {
        self.results = results
        self.generation = generation
        self.dictionaryCount = dictionaryCount
    }

    public init(response: JSONValue) throws(HachidoriError) {
        guard let page = try? response.decode(Reply.self) else { throw .malformed("an unreadable lookup reply") }
        self.init(results: page.results.map(TermLookupResult.init), generation: page.generation ?? 0,
                  dictionaryCount: page.dictionaryCount ?? 0)
    }

    struct Reply: Decodable {
        var results: [Result]
        var generation: Int?
        var dictionaryCount: Int?
    }

    struct Result: Decodable {
        var matched: String
        var deinflected: String
        var trace: [Trace]?
        var preprocessorSteps: Int?
        var term: Term
    }

    struct Trace: Decodable {
        var name: String
        var description: String?
    }

    struct Term: Decodable {
        var expression: String
        var reading: String
        var rules: String?
        /// A double in Hachidori's engine (int32 in ours).
        var score: Double?
        var glossaries: [GlossaryEntry]?
        var frequencies: [FrequencyEntry]?
        var pitches: [PitchEntry]?
    }

    struct GlossaryEntry: Decodable {
        var dictionary: String
        var glossary: String
        var definitionTags: String?
        var termTags: String?
    }

    struct FrequencyEntry: Decodable {
        var dictionary: String
        var frequencies: [FrequencyValue]
    }

    struct FrequencyValue: Decodable {
        var value: Double
        var displayValue: String?
    }

    struct PitchEntry: Decodable {
        var dictionary: String
        var pitches: [Pitch]
    }

    struct Pitch: Decodable {
        var position: Int
        var pattern: String?
        var nasal: [Int]?
        var devoice: [Int]?
    }
}

private func words(_ value: String?) -> [String] {
    (value ?? "").split(separator: " ").map(String.init)
}

extension TermLookupResult {
    init(_ result: HostLookupPage.Result) {
        let term = result.term
        self.init(
            matched: result.matched,
            deinflected: result.deinflected,
            expression: term.expression,
            reading: term.reading,
            rules: words(term.rules),
            score: term.score ?? 0,
            // Like our engine, the host lists the trace from the surface form inward; Yomitan shows base outward.
            inflections: (result.trace ?? []).map { Inflection(name: $0.name, description: $0.description ?? "") }.reversed(),
            preprocessorSteps: result.preprocessorSteps ?? 0,
            glossaries: (term.glossaries ?? []).map {
                Glossary(dictionary: $0.dictionary, json: $0.glossary, definitionTags: words($0.definitionTags), termTags: words($0.termTags))
            },
            frequencies: (term.frequencies ?? []).map { entry in
                FrequencyGroup(dictionary: entry.dictionary, values: entry.frequencies.map {
                    let value = Int($0.value.rounded())
                    let display = $0.displayValue ?? ""
                    return Frequency(value: value, display: display.isEmpty ? String(value) : display)
                })
            },
            pitches: (term.pitches ?? []).map { entry in
                PitchGroup(dictionary: entry.dictionary, accents: entry.pitches.map {
                    PitchAccent(downstep: $0.position, pattern: ($0.pattern ?? "").isEmpty ? nil : $0.pattern,
                                nasal: $0.nasal ?? [], devoice: $0.devoice ?? [])
                })
            }
        )
    }
}
