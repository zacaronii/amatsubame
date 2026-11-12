import Dictionary
import Foundation

/// Builds the popup's HTML: one block per result, Yomitan-style.
public enum EntryRenderer {
    /// `mined` (one flag per result) adds the Add to Anki button, checked for words already mined.
    public static func entries(_ results: [TermLookupResult], mined: [Bool]? = nil) -> String {
        if results.isEmpty {
            return "<div class=\"no-results\">No results</div>"
        }
        return results.enumerated().map { index, result in
            entry(result, index: index, mined: mined.map { index < $0.count && $0[index] })
        }.joined()
    }

    /// The source text with the matched span highlighted; tapping another word in it looks that up.
    public static func source(_ source: LookupSource) -> String {
        let text = source.text as NSString
        let start = min(max(source.utf16Offset, 0), text.length)
        let end = min(start + max(source.utf16Length, 0), text.length)
        let before = text.substring(to: start), match = text.substring(with: NSRange(location: start, length: end - start))
        let after = text.substring(from: end)
        return "<div class=\"source\" lang=\"ja\">\(HTML.escape(before))<mark>\(HTML.escape(match))</mark>\(HTML.escape(after))</div>"
    }

    static func entry(_ result: TermLookupResult, index: Int, mined: Bool? = nil) -> String {
        var html = "<article class=\"entry\" data-index=\"\(index)\">"
        html += "<header class=\"headword\"><span class=\"expression\" lang=\"ja\">\(headword(result))</span>"
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
        if !frequencies.isEmpty {
            html += "<div class=\"frequencies\">" + frequencies.map { group in
                "<span class=\"frequency\"><span class=\"frequency-dictionary\">\(HTML.escape(group.dictionary))</span>"
                    + "<span class=\"frequency-value\">\(group.values.map { HTML.escape($0.display) }.joined(separator: " / "))</span></span>"
            }.joined() + "</div>"
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
