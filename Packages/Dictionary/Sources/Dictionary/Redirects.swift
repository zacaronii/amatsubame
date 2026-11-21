import Foundation

/// Jitendex stores some spellings as redirects: 精いっぱい's only definitions are a link
/// "⟶ 精一杯" and a Yomitan deinflection definition `["精一杯", ["redirected from 精いっぱい"]]`.
/// Yomitan follows those (looks up 精一杯 and shows it with the note, like an inflection);
/// so do we. The redirect's own glossary goes, and so does the result when nothing else is left.
nonisolated public enum Redirects {
    /// A redirect in a result: the term to look up, its reading when the link names one, and
    /// the rules to show ("redirected from 精いっぱい").
    struct Target: Equatable {
        var term: String
        var reading: String?
        var rules: [String]
    }

    /// The terms the results redirect to, for the caller to look up.
    public static func terms(in results: [TermLookupResult]) -> [String] {
        var seen = Set<String>()
        return results.flatMap { $0.glossaries.flatMap(targets) }.map(\.term).filter { seen.insert($0).inserted }
    }

    /// `found` is each target term's lookup (the engine's or the host's).
    public static func follow(_ results: [TermLookupResult], found: [String: [TermLookupResult]]) -> [TermLookupResult] {
        guard results.contains(where: { $0.glossaries.contains(where: isRedirect) }) else { return results }
        var followed: [TermLookupResult] = []
        var shown = Set(results.map { "\($0.expression)\t\($0.reading)" })
        for result in results {
            let targets = result.glossaries.flatMap(targets)
            guard !targets.isEmpty else {
                followed.append(result)
                continue
            }
            var entries: [TermLookupResult] = []
            for target in targets {
                for var entry in found[target.term] ?? []
                where entry.matched == target.term && entry.expression == target.term
                    && (target.reading == nil || entry.reading == target.reading)
                    && shown.insert("\(entry.expression)\t\(entry.reading)").inserted {
                    entry.matched = result.matched
                    entry.inflections = result.inflections + target.rules.map { Inflection(name: $0) }
                    entry.preprocessorSteps = result.preprocessorSteps
                    entries.append(entry)
                }
            }
            followed += entries
            // Nothing found (the target's dictionary is off): the redirect stays as it is.
            guard !entries.isEmpty else {
                followed.append(result)
                continue
            }
            var rest = result
            rest.glossaries.removeAll(where: isRedirect)
            if !rest.glossaries.isEmpty { followed.append(rest) }
        }
        return followed
    }

    /// A glossary with a deinflection definition (`[term, [rules]]`).
    static func isRedirect(_ glossary: Glossary) -> Bool {
        !targets(glossary).isEmpty
    }

    static func targets(_ glossary: Glossary) -> [Target] {
        guard glossary.json.contains("[\""),
              let data = glossary.json.data(using: .utf8),
              let definitions = (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) as? [Any] else { return [] }
        let readings = linkReadings(glossary.json)
        return definitions.compactMap { definition in
            guard let pair = definition as? [Any], let term = pair.first as? String, !term.isEmpty else { return nil }
            return Target(term: term, reading: readings[term], rules: (pair.dropFirst().first as? [String]) ?? [])
        }
    }

    /// Jitendex's redirect links: `?query=精一杯&…&primary_reading=せいいっぱい`, by term.
    static func linkReadings(_ json: String) -> [String: String] {
        var readings: [String: String] = [:]
        for part in json.components(separatedBy: "\"href\"").dropFirst() {
            guard let start = part.firstIndex(of: "?"),
                  let end = part[part.index(after: start)...].firstIndex(of: "\""),
                  let items = URLComponents(string: String(part[start..<end]))?.queryItems,
                  let term = items.first(where: { $0.name == "query" })?.value,
                  let reading = items.first(where: { $0.name == "primary_reading" })?.value else { continue }
            readings[term] = reading
        }
        return readings
    }
}
