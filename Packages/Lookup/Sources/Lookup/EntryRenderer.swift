import Core
import Dictionary
import Foundation

/// Builds the popup's HTML: one block per result, Yomitan-style.
public enum EntryRenderer {
    /// `mined` (one flag per result) adds the Add to Anki button, checked for words already mined.
    /// The first result's lookup count, shown after its frequencies when lookup counts are on.
    /// `value` is nil while the visit isn't recorded yet: the chip's place is kept, empty, and
    /// filled in by `LookupWebView` when the count arrives.
    public struct LookupCount: Equatable, Sendable {
        public var value: Int?
        public init(_ value: Int?) { self.value = value }
    }

    /// Settings ▸ Popup ▸ First Meaning: which dictionary first, and how many snippets.
    public struct SummaryOptions: Equatable, Sendable {
        public var dictionary: String?
        public var count: Int
        public init(dictionary: String? = nil, count: Int = CompactDefinitionSummary.defaultCount) {
            self.dictionary = dictionary
            self.count = count
        }
    }

    /// `statuses` (one per result) adds the Known and Ignore buttons, pressed for the word's mark.
    /// `noDictionaries`: nothing to look in yet, said as such rather than "No results".
    public static func entries(_ results: [TermLookupResult], mined: [Bool]? = nil, statuses: [WordStatus?]? = nil,
                               lookupCount: LookupCount? = nil, summary: SummaryOptions? = nil, noDictionaries: Bool = false) -> String {
        if results.isEmpty {
            return noDictionaries
                ? "<div class=\"no-results\">No dictionaries yet. Add one in the app's settings to look words up.</div>"
                : "<div class=\"no-results\">No results</div>"
        }
        return results.enumerated().map { index, result in
            entry(result, index: index, mined: mined.map { index < $0.count && $0[index] },
                  status: statuses.map { index < $0.count ? $0[index] : nil },
                  lookupCount: index == 0 ? lookupCount : nil, summary: summary)
        }.joined()
    }

    /// Hachidori's Mark as known and Ignore, as toggles: pressed shows the word's mark.
    static func statusButtons(_ result: TermLookupResult, index: Int, status: WordStatus?) -> String {
        let headword = HTML.escape(result.expression)
        func button(_ action: WordStatus, label: String, path: String) -> String {
            "<button class=\"status-button\" data-action=\"\(action.rawValue)\" data-index=\"\(index)\" data-headword=\"\(headword)\" "
                + "aria-pressed=\"\(status == action)\" aria-label=\"\(label)\" title=\"\(label)\">"
                + "<svg viewBox=\"0 0 24 24\" aria-hidden=\"true\"><path d=\"\(path)\"/></svg></button>"
        }
        return button(.known, label: "Mark as known",
                      path: "M12 2a10 10 0 1 0 0 20 10 10 0 0 0 0-20zm-1.9 14.5-4.2-4.2 1.4-1.4 2.8 2.8 6.4-6.4 1.4 1.4z")
            + button(.ignored, label: "Ignore",
                     path: "M12 7a5 5 0 0 1 4.64 6.83l2.92 2.92A11.8 11.8 0 0 0 23 12c-1.73-4.39-6-7.5-11-7.5-1.4 0-2.74.25-3.98.7l2.16 2.16A4.86 4.86 0 0 1 12 7zM2 4.27l2.74 2.74A11.8 11.8 0 0 0 1 12c1.73 4.39 6 7.5 11 7.5 1.55 0 3.03-.3 4.38-.84L19.73 22 21 20.73 3.27 3zm5.53 5.53 1.55 1.55A3 3 0 0 0 12 15c.22 0 .44-.03.65-.08l1.55 1.55A5 5 0 0 1 7.53 9.8zm4.31-.78 3.15 3.15.01-.16a3 3 0 0 0-3-3z")
    }

    /// Hachidori's wording (render/popup.js formatLookupCount).
    public static func lookupCountText(_ count: Int) -> String {
        "Looked up \(count) \(count == 1 ? "time" : "times")"
    }


    /// `status`: nil leaves out the Known and Ignore buttons; `.some(nil)` shows them unpressed.
    static func entry(_ result: TermLookupResult, index: Int, mined: Bool? = nil, status: WordStatus?? = nil,
                      lookupCount: LookupCount? = nil, summary: SummaryOptions? = nil) -> String {
        var html = "<article class=\"entry\" data-index=\"\(index)\">"
        html += "<header class=\"headword\"><div class=\"headword-text\"><span class=\"expression\" lang=\"ja\">\(headword(result))</span>"
        if let summary, let compact = CompactDefinitionSummary.extract(result.glossaries, preferredDictionary: summary.dictionary,
                                                                       maximumItems: summary.count) {
            html += compactSummary(compact)
        }
        html += "</div>"
        if let status { html += statusButtons(result, index: index, status: status) }
        html += "<button class=\"audio-button\" data-action=\"audio\" data-index=\"\(index)\" aria-label=\"Play audio\">"
            + "<svg viewBox=\"0 0 24 24\" aria-hidden=\"true\"><path d=\"M4 9v6h4l5 4V5L8 9H4zm12.5 3a4.5 4.5 0 0 0-2.5-4v8a4.5 4.5 0 0 0 2.5-4z\"/></svg></button>"
        if let mined {
            html += "<button class=\"mine-button\(mined ? " mined" : "")\" data-action=\"mine\" data-index=\"\(index)\" aria-label=\"Add to Anki\">"
                + "<svg class=\"add\" viewBox=\"0 0 24 24\" aria-hidden=\"true\"><path d=\"M11 5h2v6h6v2h-6v6h-2v-6H5v-2h6z\"/></svg>"
                + "<svg class=\"done\" viewBox=\"0 0 24 24\" aria-hidden=\"true\"><path d=\"M9.5 16.2 5.3 12l-1.4 1.4 5.6 5.6L20.1 8.4 18.7 7z\"/></svg></button>"
        }
        html += "</header>"
        if !result.inflections.isEmpty {
            html += "<div class=\"inflections\">" + result.inflections.map {
                "<span class=\"inflection\" title=\"\(HTML.escape($0.description))\">\(HTML.escape($0.name))</span>"
            }.joined(separator: "<span class=\"inflection-separator\">«</span>") + "</div>"
        }
        let frequencies = result.frequencies.filter { !$0.values.isEmpty }
        if !frequencies.isEmpty || lookupCount != nil {
            html += "<div class=\"frequencies\">" + frequencies.map { group in
                "<span class=\"frequency\"><span class=\"frequency-dictionary\">\(HTML.escape(group.dictionary))</span>"
                    + "<span class=\"frequency-value\">\(group.values.map { HTML.escape($0.display) }.joined(separator: " / "))</span></span>"
            }.joined()
            if let lookupCount {
                let text = lookupCount.value.map(lookupCountText) ?? ""
                html += "<span class=\"lookup-count\" role=\"status\" data-placeholder=\"\(lookupCountText(99))\">\(text)</span>"
            }
            html += "</div>"
        }
        for group in result.pitches where !group.accents.isEmpty {
            html += "<div class=\"pitch-group\"><span class=\"pitch-dictionary\">\(HTML.escape(group.dictionary))</span>"
            html += group.accents.map { pitch($0, reading: result.reading.isEmpty ? result.expression : result.reading) }.joined()
            html += "</div>"
        }
        html += "<div class=\"glossaries\">"
        var previousDictionary: String?
        for glossary in result.glossaries {
            // The dictionary's name once, over its senses.
            if glossary.dictionary != previousDictionary {
                html += "<div class=\"dictionary-name\">" + bookIcon + HTML.escape(displayName(glossary.dictionary)) + "</div>"
                previousDictionary = glossary.dictionary
            }
            let tags = glossary.definitionTags + glossary.termTags
            html += "<section class=\"glossary\" data-dictionary=\"\(HTML.escape(glossary.dictionary))\">"
            html += "<div class=\"glossary-header\">" + tags.map(tag).joined() + "</div>"
            html += highlightingExamples(StructuredContentRenderer(dictionary: glossary.dictionary).render(glossaryJSON: glossary.json),
                                         of: result)
            html += "</section>"
        }
        html += "</div></article>"
        return html
    }

    static let bookIcon = "<svg viewBox=\"0 0 24 24\" aria-hidden=\"true\"><path d=\"M6 3h11a2 2 0 0 1 2 2v14a1 1 0 0 1-1 1H7a3 3 0 0 1-3-3V5a2 2 0 0 1 2-2zm0 2v10.2A3 3 0 0 1 7 15h10V5H6zm1 12a1 1 0 0 0 0 2h10v-2H7z\"/></svg>"

    /// A dictionary's title without the date its importer adds: "JMdict [2025-11-01]" → "JMdict".
    static func displayName(_ dictionary: String) -> String {
        let trimmed = dictionary.replacingOccurrences(of: #"\s*\[[^\]]*\]\s*$"#, with: "", options: .regularExpression)
        return trimmed.isEmpty ? dictionary : trimmed
    }

    /// A tag chip; a bare number is the sense number, drawn as a filled circle.
    static func tag(_ name: String) -> String {
        name.allSatisfy(\.isNumber) && !name.isEmpty
            ? "<span class=\"sense-number\">\(HTML.escape(name))</span>"
            : "<span class=\"tag\">\(HTML.escape(name))</span>"
    }

    /// Marks the looked-up word in each Japanese example sentence (JMdict's `examples` lists):
    /// the first of the matched text, the headword or its reading found in the sentence.
    static func highlightingExamples(_ html: String, of result: TermLookupResult) -> String {
        let marker = "data-sc-content=\"examples\""
        guard html.contains(marker) else { return html }
        let candidates = Set([result.matched, result.expression, result.reading, result.deinflected].filter { !$0.isEmpty })
            .map(HTML.escape).sorted { $0.count > $1.count }
        var output = "", rest = Substring(html)
        while let list = rest.range(of: marker) {
            output += rest[..<list.upperBound]
            rest = rest[list.upperBound...]
            // The first item of the list is the Japanese sentence.
            guard let open = rest.range(of: "<li"), let start = rest[open.upperBound...].range(of: ">"),
                  let end = rest[start.upperBound...].range(of: "</li>") else { continue }
            let sentence = String(rest[start.upperBound..<end.lowerBound])
            output += rest[..<start.upperBound]
            if !sentence.contains("<"), let word = candidates.first(where: sentence.contains),
               let found = sentence.range(of: word) {
                output += sentence[..<found.lowerBound] + "<span class=\"example-word\">\(word)</span>" + sentence[found.upperBound...]
            } else {
                output += sentence
            }
            rest = rest[end.lowerBound...]
        }
        return output + rest
    }

    /// Hachidori's compact summary beside the headword: an optional 36 px image, then the
    /// snippets, which CSS joins with " · ".
    static func compactSummary(_ summary: CompactDefinitionSummary) -> String {
        var html = "<div class=\"compact-summary\" data-dictionary=\"\(HTML.escape(summary.dictionary))\">"
        if let path = summary.imagePath {
            let src = StructuredContentRenderer(dictionary: summary.dictionary).mediaURL(path)
            html += "<span class=\"compact-summary-image\"><img src=\"\(src)\" alt=\"\"></span>"
        }
        html += "<ul class=\"compact-summary-items\">" + summary.items.map { "<li>\(HTML.escape($0))</li>" }.joined() + "</ul></div>"
        return html
    }

    /// The headword with ruby furigana over its kanji.
    static func headword(_ result: TermLookupResult) -> String {
        Furigana.segments(expression: result.expression, reading: result.reading).map { segment in
            guard let reading = segment.reading else { return HTML.escape(segment.text) }
            return "<ruby>\(HTML.escape(segment.text))<rt>\(HTML.escape(reading))</rt></ruby>"
        }.joined()
    }

    /// Reading with an overline over high morae and a drop mark at the downstep.
    static func pitch(_ accent: PitchAccent, reading: String) -> String {
        let graph = PitchGraph(reading: reading, downstep: accent.downstep)
        var html = "<span class=\"pitch\" data-pattern=\"\(graph.pattern.rawValue)\"><span class=\"pitch-text\" lang=\"ja\">"
        for (index, mora) in graph.morae.enumerated() {
            var classes = graph.highs[index] ? "mora high" : "mora low"
            if accent.downstep > 0 && index + 1 == accent.downstep { classes += " downstep" }
            html += "<span class=\"\(classes)\">\(HTML.escape(mora))</span>"
        }
        html += "</span><span class=\"pitch-number\">[\(accent.downstep)]</span></span>"
        return html
    }
}

/// The full popup document: theme CSS, dictionary CSS scoped per dictionary, and the tap bridge.
public enum LookupPage {
    public static func document(body: String, dictionaryStyles: [String: String], fontSize: Int = 16, extraCSS: String = "") -> String {
        let scoped = dictionaryStyles.sorted { $0.key < $1.key }.map { title, css in
            "[data-dictionary=\"\(cssString(title))\"] {\n\(css)\n}"
        }.joined(separator: "\n")
        return """
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
        <style>\(resource("popup", "css"))</style>
        <style>:root { --font-size-no-units: \(fontSize); font-size: \(fontSize)px; }</style>
        <style>\(scoped)</style>
        <style>\(extraCSS)</style>
        </head><body><main id="entries">\(body)</main>
        <script>\(resource("TextTapBridge", "js"))</script>
        </body></html>
        """
    }

    /// The shared tap-to-look-up script, for web views that load their own pages (the book reader).
    public static var tapBridgeScript: String { resource("TextTapBridge", "js") }

    static func cssString(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    static func resource(_ name: String, _ ext: String) -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Web") else { return "" }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }
}
