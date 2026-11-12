import Foundation

/// Renders Yomitan glossary JSON to HTML the way Yomitan's StructuredContentGenerator
/// builds its DOM, so dictionary stylesheets (Jitendex's `[data-sc-content=…]` rules)
/// apply unchanged. Images load from `dictmedia://`; `?query=` links become lookups.
public struct StructuredContentRenderer: Sendable {
    public static let mediaScheme = "dictmedia"

    public let dictionary: String

    public init(dictionary: String) {
        self.dictionary = dictionary
    }

    /// Renders a term's definitions (the glossary JSON array). Several definitions become a list.
    public func render(glossaryJSON: String) -> String {
        guard let data = glossaryJSON.data(using: .utf8),
              let definitions = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return "<div class=\"gloss-content\">\(HTML.escape(glossaryJSON))</div>"
        }
        let items = (definitions as? [Any]) ?? [definitions]
        let rendered = items.map(renderDefinition).filter { !$0.isEmpty }
        if rendered.count == 1 { return "<div class=\"gloss-content\">\(rendered[0])</div>" }
        return "<ol class=\"gloss-list\">" + rendered.map { "<li class=\"gloss-item\"><div class=\"gloss-content\">\($0)</div></li>" }.joined() + "</ol>"
    }

    /// The glosses of a term's definitions as plain text, one list per sense: each Jitendex
    /// `glossary` list, or a definition's plain strings. Examples, notes and references are left
    /// out, and so are dictionaries without glosses (prose ones like 新和英).
    public static func glosses(glossaryJSON: String) -> [[String]] {
        guard let data = glossaryJSON.data(using: .utf8),
              let definitions = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return [] }
        var senses: [[String]] = []
        var strings: [String] = []
        for definition in (definitions as? [Any]) ?? [definitions] {
            if let text = definition as? String {
                strings.append(text)
            } else if let object = definition as? [String: Any] {
                switch object["type"] as? String {
                case "text": strings.append(object["text"] as? String ?? "")
                case "structured-content": senses += glossaryLists(object["content"])
                default: break
                }
            }
        }
        strings = strings.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return (strings.isEmpty ? [] : [strings]) + senses
    }

    private static func glossaryLists(_ value: Any?) -> [[String]] {
        switch value {
        case let array as [Any]:
            return array.flatMap(glossaryLists)
        case let object as [String: Any]:
            if (object["data"] as? [String: Any])?["content"] as? String == "glossary" {
                let items = (object["content"] as? [Any]) ?? [object["content"] as Any]
                let glosses = items.map(plainText).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                return glosses.isEmpty ? [] : [glosses]
            }
            return glossaryLists(object["content"])
        default:
            return []
        }
    }

    /// An element's text, without ruby readings or images.
    private static func plainText(_ value: Any?) -> String {
        switch value {
        case let text as String: text
        case let array as [Any]: array.map(plainText).joined()
        case let object as [String: Any]:
            ["rt", "rp", "img"].contains(object["tag"] as? String ?? "") ? "" : plainText(object["content"])
        default: ""
        }
    }

    func renderDefinition(_ definition: Any) -> String {
        if let text = definition as? String { return HTML.escape(text) }
        if let deinflection = definition as? [Any], let base = deinflection.first as? String {
            // Format-3 "deinflection" definition: [base form, [rules]].
            return "<span class=\"gloss-deinflection\">→ \(HTML.escape(base))</span>"
        }
        guard let object = definition as? [String: Any] else { return "" }
        switch object["type"] as? String {
        case "text": return HTML.escape(object["text"] as? String ?? "")
        case "structured-content": return "<span class=\"structured-content\">\(content(object["content"]))</span>"
        case "image": return image(object)
        default: return ""
        }
    }

    func content(_ value: Any?) -> String {
        switch value {
        case let text as String: return HTML.escape(text)
        case let array as [Any]: return array.map(content).joined()
        case let object as [String: Any]: return element(object)
        default: return ""
        }
    }

    private static let simpleTags: Set<String> = ["div", "span", "ol", "ul", "li", "details", "summary"]
    private static let tableParts: Set<String> = ["thead", "tbody", "tfoot", "tr"]

    func element(_ object: [String: Any]) -> String {
        guard let tag = object["tag"] as? String else { return "" }
        switch tag {
        case "br":
            return "<br class=\"gloss-sc-br\">"
        case "ruby", "rt", "rp":
            return wrap(tag, object, styled: false)
        case "table":
            return "<div class=\"gloss-sc-table-container\">\(wrap(tag, object, styled: false))</div>"
        case _ where Self.tableParts.contains(tag):
            return wrap(tag, object, styled: false)
        case "th", "td":
            var extra = ""
            if let colSpan = object["colSpan"] as? Int { extra += " colspan=\"\(colSpan)\"" }
            if let rowSpan = object["rowSpan"] as? Int { extra += " rowspan=\"\(rowSpan)\"" }
            return wrap(tag, object, styled: true, extraAttributes: extra)
        case _ where Self.simpleTags.contains(tag):
            return wrap(tag, object, styled: true)
        case "img":
            return image(object)
        case "a":
            return link(object)
        default:
            return content(object["content"])
        }
    }

    private func wrap(_ tag: String, _ object: [String: Any], styled: Bool, extraAttributes: String = "") -> String {
        var attributes = "class=\"gloss-sc-\(tag)\"" + extraAttributes
        if let lang = object["lang"] as? String { attributes += " lang=\"\(HTML.escape(lang))\"" }
        if let data = object["data"] as? [String: Any] {
            for (key, value) in data.sorted(by: { $0.key < $1.key }) where !key.isEmpty {
                let name = "sc" + key.prefix(1).uppercased() + key.dropFirst()
                attributes += " data-\(HTML.kebab(name))=\"\(HTML.escape("\(value)"))\""
            }
        }
        if styled {
            if let style = object["style"] as? [String: Any] {
                let css = Self.css(style)
                if !css.isEmpty { attributes += " style=\"\(HTML.escape(css))\"" }
            }
            if let title = object["title"] as? String { attributes += " title=\"\(HTML.escape(title))\"" }
            if object["open"] as? Bool == true { attributes += " open" }
        }
        return "<\(tag) \(attributes)>\(content(object["content"]))</\(tag)>"
    }

    /// The style properties Yomitan allows; numeric margins are in em.
    static func css(_ style: [String: Any]) -> String {
        let passthrough = [
            "fontStyle", "fontWeight", "fontSize", "color", "background", "backgroundColor", "verticalAlign",
            "textAlign", "textEmphasis", "textShadow", "textDecorationStyle", "textDecorationColor", "borderColor",
            "borderStyle", "borderRadius", "borderWidth", "clipPath", "margin", "padding", "paddingTop",
            "paddingLeft", "paddingRight", "paddingBottom", "wordBreak", "whiteSpace", "cursor", "listStyleType",
        ]
        var declarations: [String] = []
        for key in passthrough {
            if let value = style[key] as? String { declarations.append("\(HTML.kebab(key)): \(value)") }
        }
        if let line = style["textDecorationLine"] as? String {
            declarations.append("text-decoration: \(line)")
        } else if let lines = style["textDecorationLine"] as? [String] {
            declarations.append("text-decoration: \(lines.joined(separator: " "))")
        }
        for key in ["marginTop", "marginLeft", "marginRight", "marginBottom"] {
            if let number = style[key] as? NSNumber, !(style[key] is String) {
                declarations.append("\(HTML.kebab(key)): \(number)em")
            } else if let value = style[key] as? String {
                declarations.append("\(HTML.kebab(key)): \(value)")
            }
        }
        return declarations.joined(separator: "; ")
    }

    func image(_ object: [String: Any]) -> String {
        guard let path = object["path"] as? String else { return "" }
        let width = Self.double(object["width"]) ?? 100
        let height = Self.double(object["height"]) ?? 100
        let preferredWidth = Self.double(object["preferredWidth"])
        let preferredHeight = Self.double(object["preferredHeight"])
        let inverseAspect = (preferredWidth != nil && preferredHeight != nil) ? preferredHeight! / preferredWidth! : height / width
        let usedWidth = preferredWidth ?? preferredHeight.map { $0 / inverseAspect } ?? width
        let unit = (object["sizeUnits"] as? String) == "em" ? "em" : "px"
        var containerStyle = "width: \(Self.number(usedWidth))\(unit)"
        if let border = object["border"] as? String { containerStyle += "; border: \(border)" }
        if let radius = object["borderRadius"] as? String { containerStyle += "; border-radius: \(radius)" }
        var linkAttributes = "class=\"gloss-image-link\""
        if let align = object["verticalAlign"] as? String { linkAttributes += " data-vertical-align=\"\(HTML.escape(align))\" style=\"vertical-align: \(HTML.escape(align))\"" }
        if let rendering = object["imageRendering"] as? String { linkAttributes += " data-image-rendering=\"\(HTML.escape(rendering))\"" }
        if object["pixelated"] as? Bool == true { linkAttributes += " data-image-rendering=\"pixelated\"" }
        if let appearance = object["appearance"] as? String { linkAttributes += " data-appearance=\"\(HTML.escape(appearance))\"" }
        let title = (object["title"] as? String).map { " title=\"\(HTML.escape($0))\"" } ?? ""
        let alt = HTML.escape(object["alt"] as? String ?? object["title"] as? String ?? "")
        return "<span \(linkAttributes)\(title)><span class=\"gloss-image-container\" style=\"\(HTML.escape(containerStyle))\">"
            + "<img class=\"gloss-image\" src=\"\(mediaURL(path))\" alt=\"\(alt)\" style=\"width: 100%; aspect-ratio: \(Self.number(1 / inverseAspect))\">"
            + "</span></span>"
    }

    func mediaURL(_ path: String) -> String {
        var components = URLComponents()
        components.scheme = Self.mediaScheme
        components.host = "media"
        components.path = "/" + path
        components.queryItems = [URLQueryItem(name: "dictionary", value: dictionary)]
        return HTML.escape(components.string ?? "")
    }

    func link(_ object: [String: Any]) -> String {
        let href = object["href"] as? String ?? ""
        let text = "<span class=\"gloss-link-text\">\(content(object["content"]))</span>"
        let lang = (object["lang"] as? String).map { " lang=\"\(HTML.escape($0))\"" } ?? ""
        if href.hasPrefix("?") {
            // Internal lookup link, e.g. "?query=食べる&wildcards=off".
            let query = URLComponents(string: "x:" + href)?.queryItems?.first { $0.name == "query" }?.value ?? ""
            return "<a class=\"gloss-link\" data-external=\"false\" data-lookup=\"\(HTML.escape(query))\"\(lang)>\(text)</a>"
        }
        return "<a class=\"gloss-link\" data-external=\"true\" href=\"\(HTML.escape(href))\"\(lang)>\(text)</a>"
    }

    /// JSON numbers arrive as NSNumber, Int or Double depending on the source.
    private static func double(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber where !(value is Bool): number.doubleValue
        case let int as Int: Double(int)
        case let double as Double: double
        default: nil
        }
    }

    private static func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.4g", value)
    }
}
