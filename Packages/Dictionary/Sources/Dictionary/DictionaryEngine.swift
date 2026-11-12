import CHoshiDicts
import Foundation

/// A dictionary the engine loads, in the order results should list it.
public struct EngineDictionary: Equatable, Sendable {
    public var title: String
    public var folder: URL
    public var hasTerms: Bool
    public var hasFrequencies: Bool
    public var hasPitches: Bool
    public var hasKanji: Bool

    public init(title: String, folder: URL, hasTerms: Bool, hasFrequencies: Bool, hasPitches: Bool, hasKanji: Bool) {
        self.title = title
        self.folder = folder
        self.hasTerms = hasTerms
        self.hasFrequencies = hasFrequencies
        self.hasPitches = hasPitches
        self.hasKanji = hasKanji
    }
}

/// hoshidicts handles, freed in the order the C API requires: a lookup holds
/// references into its query and deinflector, so it goes first.
final class Deinflector {
    let pointer = hd_deinflector_new()!
    deinit { hd_deinflector_free(pointer) }
}

final class QueryHandles {
    let deinflector: Deinflector
    let query: OpaquePointer
    let lookup: OpaquePointer

    /// Takes ownership of `query`.
    init(query: OpaquePointer, deinflector: Deinflector) {
        self.deinflector = deinflector
        self.query = query
        lookup = hd_lookup_new(query, deinflector.pointer)!
    }

    deinit {
        hd_lookup_free(lookup)
        hd_query_free(query)
    }
}

/// Owns hoshidicts' query, deinflector and lookup. Every C call goes through
/// this actor, so lookups never race with dictionaries being changed.
public actor DictionaryEngine {
    private let deinflector = Deinflector()
    private var handles: QueryHandles
    private var frequencySortTitle: String?
    public private(set) var dictionaries: [EngineDictionary] = []

    private var query: OpaquePointer { handles.query }
    private var lookupHandle: OpaquePointer { handles.lookup }

    public init() {
        handles = QueryHandles(query: hd_query_new()!, deinflector: deinflector)
    }

    /// Replaces the loaded dictionaries. The lookup keeps references into the
    /// query, so both are rebuilt together.
    public func configure(_ dictionaries: [EngineDictionary], frequencySortTitle: String?) throws(DictionaryError) {
        let newQuery = hd_query_new()!
        for dictionary in dictionaries {
            let path = dictionary.folder.path(percentEncoded: false)
            var failed = false
            if dictionary.hasTerms { failed = failed || hd_query_add_term_dict(newQuery, path) != 0 }
            if dictionary.hasFrequencies { failed = failed || hd_query_add_freq_dict(newQuery, path) != 0 }
            if dictionary.hasPitches { failed = failed || hd_query_add_pitch_dict(newQuery, path) != 0 }
            if dictionary.hasKanji { failed = failed || hd_query_add_kanji_dict(newQuery, path) != 0 }
            if failed {
                hd_query_free(newQuery)
                throw .unreadable(dictionary.title)
            }
        }
        handles = QueryHandles(query: newQuery, deinflector: deinflector)
        self.dictionaries = dictionaries
        self.frequencySortTitle = frequencySortTitle
            ?? dictionaries.first(where: \.hasFrequencies)?.title
    }

    /// Finds the longest dictionary matches at the start of `text`, deinflecting
    /// each prefix. Pass the text from the tapped character onward.
    public func lookup(_ text: String, maxResults: Int = 16, scanLength: Int = 16) -> [TermLookupResult] {
        guard !text.isEmpty else { return [] }
        let lookupHandle = lookupHandle
        let sortTitle = frequencySortTitle
        return text.withCString { textPointer in
            (sortTitle ?? "").withCString { sortPointer in
                var options = hd_lookup_options(
                    frequency_dictionary: sortTitle == nil
                        ? hd_str(ptr: nil, len: 0)
                        : hd_str(ptr: sortPointer, len: strlen(sortPointer)),
                    frequency_order: Int32(HD_LOOKUP_FREQUENCY_ORDER_AUTO.rawValue),
                    primary_reading: hd_str(ptr: nil, len: 0)
                )
                var results: UnsafePointer<hd_lookup_result>?
                var count = 0
                guard let handle = hd_lookup_run_with_options(
                    lookupHandle, textPointer, Int32(maxResults), scanLength, &options, &results, &count
                ) else { return [] }
                // Results point into `handle`; copy them into Swift values before freeing.
                defer { hd_lookup_results_free(handle) }
                return (0..<count).map { TermLookupResult(results![$0]) }
            }
        }
    }

    /// CSS shipped with each dictionary, keyed by dictionary title.
    public func styles() -> [String: String] {
        var styles: UnsafePointer<hd_dictionary_style>?
        var count = 0
        guard let handle = hd_query_get_styles(query, &styles, &count) else { return [:] }
        defer { hd_styles_free(handle) }
        var result: [String: String] = [:]
        for index in 0..<count {
            result[styles![index].dict_name.string] = styles![index].styles.string
        }
        return result
    }

    /// An image or other file from a term dictionary (structured-content images).
    public func mediaFile(dictionary: String, path: String) -> Data? {
        let file = dictionary.withCString { dict in path.withCString { hd_query_get_media_file(query, dict, $0) } }
        guard let data = file.data, file.size > 0 else { return nil }
        // The bytes point into the query's mapped files; copy before returning.
        return Data(bytes: data, count: file.size)
    }
}

extension hd_str {
    var string: String {
        guard let ptr, len > 0 else { return "" }
        return String(decoding: UnsafeRawBufferPointer(start: ptr, count: len), as: UTF8.self)
    }
}

private func words(_ value: hd_str) -> [String] {
    value.string.split(separator: " ").map(String.init)
}

extension TermLookupResult {
    init(_ result: hd_lookup_result) {
        let term = result.term
        // hoshidicts lists the trace from the surface form inward; Yomitan shows base outward.
        let trace = (0..<result.trace_count).map {
            Inflection(name: result.trace![$0].name.string, description: result.trace![$0].description.string)
        }
        self.init(
            matched: result.matched.string,
            deinflected: result.deinflected.string,
            expression: term.expression.string,
            reading: term.reading.string,
            rules: words(term.rules),
            score: Int(term.score),
            inflections: trace.reversed(),
            preprocessorSteps: Int(result.preprocessor_steps),
            glossaries: (0..<term.glossaries_count).map {
                let entry = term.glossaries![$0]
                return Glossary(dictionary: entry.dict_name.string, json: entry.glossary.string,
                                definitionTags: words(entry.definition_tags), termTags: words(entry.term_tags))
            },
            frequencies: (0..<term.frequencies_count).map {
                let entry = term.frequencies![$0]
                return FrequencyGroup(dictionary: entry.dict_name.string, values: (0..<entry.frequencies_count).map {
                    let frequency = entry.frequencies![$0]
                    let display = frequency.display_value.string
                    return Frequency(value: Int(frequency.value), display: display.isEmpty ? String(frequency.value) : display)
                })
            },
            pitches: (0..<term.pitches_count).map {
                let entry = term.pitches![$0]
                return PitchGroup(dictionary: entry.dict_name.string, accents: (0..<entry.pitches_count).map {
                    let pitch = entry.pitches![$0]
                    let pattern = pitch.pattern.string
                    return PitchAccent(
                        downstep: Int(pitch.position),
                        pattern: pattern.isEmpty ? nil : pattern,
                        nasal: (0..<pitch.nasal_count).map { Int(pitch.nasal![$0]) },
                        devoice: (0..<pitch.devoice_count).map { Int(pitch.devoice![$0]) }
                    )
                })
            }
        )
    }
}
