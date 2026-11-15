import Dictionary
import Foundation

/// The brief definitions beside a headword ("guilt-free · sinless · innocent"): a port of
/// Hachidori's compact definition summary (bee-san/hachidori `extension/render/popup.js`,
/// `extractCompactDefinitionSummary` and its helpers, GPL-3.0), so both show the same snippets.
/// Function names follow Hachidori's; docs/hachidori.md section 5 describes the rule.
public struct CompactDefinitionSummary: Equatable, Sendable {
    public static let defaultCount = 3
    public static let counts = 1...6
    static let maxCharacters = 240
    static let maxNodes = 512

    /// The dictionary the snippets came from.
    public var dictionary: String
    public var items: [String]
    /// A leading image (`{tag: "img", path, …}`) when a definition starts with one.
    public var imagePath: String?

    static let blockTags: Set<String> = ["article", "blockquote", "dd", "div", "dt", "h1", "h2", "h3", "h4", "h5", "h6",
                                         "li", "p", "section", "td", "th", "tr"]
    static let ignoredTags: Set<String> = ["audio", "button", "canvas", "iframe", "img", "input", "rp", "rt", "script",
                                           "source", "style", "svg", "video"]

    /// The first dictionary (the preferred one first, then the result's order) that yields
    /// snippets: up to `maximumItems` unique ones, 240 characters in all.
    public static func extract(_ glossaries: [Glossary], preferredDictionary: String? = nil,
                               maximumItems: Int = defaultCount) -> CompactDefinitionSummary? {
        let itemLimit = counts.contains(maximumItems) ? maximumItems : defaultCount
        var order: [String] = []
        var byDictionary: [String: [String]] = [:]
        for glossary in glossaries {
            if byDictionary[glossary.dictionary] == nil { order.append(glossary.dictionary) }
            byDictionary[glossary.dictionary, default: []].append(glossary.json)
        }
        if let preferredDictionary, let index = order.firstIndex(of: preferredDictionary) {
            order.remove(at: index)
            order.insert(preferredDictionary, at: 0)
        }
        for dictionary in order {
            var items: [String] = [], seen: Set<String> = []
            var characterCount = 0
            var leading: Leading = .none
            for raw in byDictionary[dictionary] ?? [] {
                let parsed = parseValue(raw)
                if case .none = leading { leading = leadingImage(parsed) }
                for item in extractItems(parsed) {
                    if item.isEmpty || seen.contains(item) { continue }
                    let remaining = maxCharacters - characterCount
                    let points = Array(item.unicodeScalars.prefix(remaining + 1))
                    let bounded = points.count <= remaining ? item
                        : remaining == 1 ? "\u{2026}"
                        : String(String.UnicodeScalarView(points.prefix(remaining - 1))) + "\u{2026}"
                    items.append(bounded)
                    seen.insert(item)
                    characterCount += min(points.count, remaining)
                    if bounded != item || items.count >= itemLimit || characterCount >= maxCharacters { break }
                }
                if items.count >= itemLimit || characterCount >= maxCharacters { break }
            }
            if !items.isEmpty {
                var imagePath: String?
                if case .image(let path) = leading { imagePath = path }
                return CompactDefinitionSummary(dictionary: dictionary, items: items, imagePath: imagePath)
            }
        }
        return nil
    }

    // MARK: Values

    static func parseValue(_ raw: String) -> Any? {
        guard !raw.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(raw.utf8), options: .fragmentsAllowed)) ?? raw
    }

    static func record(_ value: Any?) -> [String: Any]? { value as? [String: Any] }

    static func marker(_ value: Any?) -> String {
        guard let data = record(value)?["data"] as? [String: Any], let content = data["content"] as? String else { return "" }
        return content.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Sanseido-style dictionaries name sections with data.name instead of markers.
    static func name(_ value: Any?) -> String {
        (record(value)?["data"] as? [String: Any])?["name"] as? String ?? ""
    }

    static func isIgnoredSection(_ value: Any?) -> Bool {
        // ルビG is Sanseido furigana, left out like rt.
        if name(value) == "ルビG" { return true }
        let marker = marker(value)
        guard !marker.isEmpty, marker != "glossary" else { return false }
        return marker.hasPrefix("part-of-speech") || marker == "redirect-glossary"
            || marker == "source" || marker.hasPrefix("source-")
            || marker == "attribution" || marker.hasPrefix("attribution-")
            || marker == "example" || marker == "examples" || marker.hasPrefix("example-")
            || marker == "form" || marker == "forms" || marker.hasPrefix("forms-")
    }

    /// Typed wrappers select their payload before incidental tags.
    static func tag(_ value: [String: Any]) -> String {
        let type = value["type"] as? String
        if type == "text" || type == "structured-content" { return "" }
        if type == "image" { return "img" }
        return (value["tag"] as? String)?.lowercased() ?? ""
    }

    static func content(_ value: [String: Any]) -> Any? {
        value["type"] as? String == "text" && value.keys.contains("text") ? value["text"] : value["content"]
    }

    static func isBlock(_ value: Any?) -> Bool {
        guard let value = record(value) else { return false }
        return blockTags.contains(tag(value))
    }

    // MARK: Text

    /// Splits text into snippets on • (U+2022), collapsing whitespace; stops after a snippet
    /// longer than 240 characters (one extra character proves the cut).
    static func itemsFromText(_ parts: [String]) -> [String] {
        var items: [String] = []
        var buffer = String.UnicodeScalarView(), count = 0
        var pendingSpace = false
        func isSpace(_ scalar: Unicode.Scalar) -> Bool { scalar.properties.isWhitespace || scalar == "\u{FEFF}" }
        for text in parts {
            let scalars = Array(text.unicodeScalars)
            var index = 0
            while index < scalars.count {
                var start = index
                while start < scalars.count, isSpace(scalars[start]) || (count == 0 && scalars[start] == "\u{2022}") { start += 1 }
                if start == scalars.count {
                    pendingSpace = count > 0
                    break
                }
                pendingSpace = pendingSpace || (count > 0 && start > index)
                if scalars[start] == "\u{2022}" {
                    items.append(String(buffer))
                    buffer = .init()
                    count = 0
                    pendingSpace = false
                    index = start + 1
                    continue
                }
                var end = start
                while end < scalars.count, !isSpace(scalars[end]), scalars[end] != "\u{2022}", end - start <= maxCharacters { end += 1 }
                index = end
                if pendingSpace {
                    buffer.append(" ")
                    count += 1
                }
                pendingSpace = false
                if count <= maxCharacters {
                    let available = maxCharacters + 1 - count
                    let run = scalars[start..<end].prefix(available)
                    buffer.append(contentsOf: run)
                    count += run.count
                }
                if count > maxCharacters {
                    items.append(String(buffer))
                    return items
                }
            }
        }
        if count > 0 { items.append(String(buffer)) }
        return items
    }

    /// An enclosing array while collecting text: a child's first text decides whether a space
    /// separates it from the text before (a block on either side does).
    final class ArrayFrame {
        let value: [Any]
        var index = 0
        var hasText = false, previousWasBlock = false, childHasText = false, childIsBlock = false
        init(_ value: [Any]) { self.value = value }
    }

    static func collectText(_ root: Any?) -> [String] {
        var parts: [String] = []
        var arrays: [ArrayFrame] = []
        var nodes = 0
        func separators() -> Int {
            var count = 0
            for array in arrays.reversed() {
                guard !array.childHasText else { break }
                array.childIsBlock = isBlock(array.index > 0 ? array.value[array.index - 1] : nil)
                if array.hasText && (array.previousWasBlock || array.childIsBlock) { count += 1 }
                array.childHasText = true
            }
            return count
        }
        func emit(_ text: String) {
            guard !text.isEmpty else { return }
            parts.append(contentsOf: Array(repeating: " ", count: separators()))
            parts.append(text)
        }
        func walk(_ value: Any?) {
            guard nodes < maxNodes else { return }
            nodes += 1
            switch value {
            case let text as String: emit(text)
            case let number as NSNumber: emit(CFGetTypeID(number) == CFBooleanGetTypeID() ? (number.boolValue ? "true" : "false") : number.stringValue)
            case let array as [Any]:
                let frame = ArrayFrame(array)
                arrays.append(frame)
                while frame.index < array.count, nodes < maxNodes {
                    frame.childHasText = false
                    frame.index += 1
                    walk(array[frame.index - 1])
                    if frame.childHasText {
                        frame.hasText = true
                        frame.previousWasBlock = frame.childIsBlock
                    }
                }
                arrays.removeLast()
            case let object as [String: Any]:
                guard !isIgnoredSection(object) else { return }
                let tag = tag(object)
                if ignoredTags.contains(tag) { return }
                if tag == "br" { emit(" ") } else if let content = content(object) { walk(content) }
            default: break
            }
        }
        walk(root)
        return parts
    }

    // MARK: Nodes

    /// The outermost nodes matching `predicate`, in document order, within the node budget.
    static func findNodes(_ root: Any?, nodes: inout Int, _ predicate: ([String: Any], String) -> Bool) -> [[String: Any]] {
        var matches: [[String: Any]] = []
        func walk(_ value: Any?) {
            guard nodes < maxNodes else { return }
            nodes += 1
            if let array = value as? [Any] {
                for child in array where nodes < maxNodes { walk(child) }
                return
            }
            guard let object = record(value), !isIgnoredSection(object) else { return }
            let tag = tag(object)
            if tag == "br" || ignoredTags.contains(tag) { return }
            if predicate(object, tag) {
                matches.append(object)
                return
            }
            if let content = content(object) { walk(content) }
        }
        walk(root)
        return matches
    }

    static func findNodes(_ root: Any?, _ predicate: ([String: Any], String) -> Bool) -> [[String: Any]] {
        var nodes = 0
        return findNodes(root, nodes: &nodes, predicate)
    }

    static func isList(_ value: [String: Any], _ tag: String) -> Bool { tag == "ul" || tag == "ol" }

    /// Block nodes with no block descendants: the smallest sense-sized chunks.
    static func leafBlocks(_ root: Any?, nodes: inout Int) -> [[String: Any]] {
        findNodes(root, nodes: &nodes) { value, tag in
            blockTags.contains(tag) && findNodes(value["content"]) { _, childTag in blockTags.contains(childTag) }.isEmpty
        }
    }

    static func leafBlocks(_ root: Any?) -> [[String: Any]] {
        var nodes = 0
        return leafBlocks(root, nodes: &nodes)
    }

    /// The snippets of each node, and whether any node had one.
    static func itemsFromNodes(_ nodes: [Any]) -> (items: [String], found: Bool) {
        var items: [String] = []
        for node in nodes.prefix(maxNodes) { items += itemsFromText(collectText(node)) }
        return (items, !items.isEmpty)
    }

    static func itemsFromList(_ list: [String: Any]) -> (items: [String], found: Bool) {
        let children = Array(((list["content"] as? [Any]) ?? [list["content"] as Any]).prefix(maxNodes))
        let listItems = children.filter { record($0).map { tag($0) == "li" } ?? false }
        return itemsFromNodes(listItems.isEmpty ? children : listItems)
    }

    static func itemsFromMarkedNode(_ node: [String: Any]) -> [String] {
        let tag = tag(node)
        if tag == "ul" || tag == "ol" { return itemsFromList(node).items }
        let content = content(node)
        let nestedLists = findNodes(content, isList)
        if !nestedLists.isEmpty { return nestedLists.flatMap { itemsFromList($0).items } }
        let leaves = leafBlocks(content)
        return itemsFromNodes(leaves.isEmpty ? [node] : leaves).items
    }

    /// Sanseido index entries list sub-headwords as bare links, not definitions.
    static func isLinkOnly(_ sense: Any?) -> Bool {
        var node = sense
        if let object = record(sense), object["type"] as? String == "structured-content" { node = object["content"] }
        guard let object = record(node) else { return false }
        return (object["tag"] as? String)?.lowercased() == "a" && tag(object) == "a"
    }

    static func isSense(_ value: [String: Any]) -> Bool {
        let name = name(value)
        return name == "語義" || name == "語釈"
    }

    /// Bilingual Sanseido conversions write a 語釈 as English, a bare " " child, then the
    /// original Japanese: only the English half is kept.
    static func englishHalf(_ gloss: [String: Any]) -> Any {
        let parts = (gloss["content"] as? [Any]) ?? [gloss["content"] as Any]
        guard let separator = parts.lastIndex(where: { $0 as? String == " " }) else { return parts }
        let rest = String(collectText(Array(parts[(separator + 1)...])).joined().prefix(65))
        let lead = rest.unicodeScalars.first { scalar in
            ("A"..."Z").contains(scalar) || ("a"..."z").contains(scalar) || ("ぁ"..."ゟ").contains(scalar) || ("ァ"..."ヿ").contains(scalar)
                || ("㐀"..."鿿").contains(scalar) || ("Ａ"..."Ｚ").contains(scalar) || ("ａ"..."ｚ").contains(scalar)
        }
        let japanese = rest.unicodeScalars.contains { ("ぁ"..."ゟ").contains($0) || ("ァ"..."ヿ").contains($0) || ("㐀"..."鿿").contains($0) }
        if let lead, !(("A"..."Z").contains(lead) || ("a"..."z").contains(lead)), japanese { return Array(parts[..<separator]) }
        return parts
    }

    /// Top-level glossary entries are separate senses: each one's leaf blocks, or itself.
    static func fallbackNodes(_ parsed: Any?) -> [Any] {
        var nodes = 0
        var result: [Any] = []
        for sense in (parsed as? [Any]) ?? [parsed as Any] {
            if isLinkOnly(sense) { continue }
            let leaves = leafBlocks(sense, nodes: &nodes)
            if leaves.isEmpty { result.append(sense) } else { result += leaves }
        }
        return result
    }

    static func extractItems(_ parsed: Any?) -> [String] {
        guard let parsed else { return [] }
        // Marked glossary sections (Jitendex) and Sanseido senses, in one pass.
        let marked = findNodes(parsed) { value, _ in marker(value) == "glossary" || isSense(value) }
        let glossaryNodes = marked.filter { marker($0) == "glossary" }
        if !glossaryNodes.isEmpty { return glossaryNodes.flatMap(itemsFromMarkedNode) }
        if !marked.isEmpty {
            // A 語義 sense holds its 語釈 gloss; 副義 sub-senses nest their own.
            return marked.flatMap { sense in
                let glosses = name(sense) == "語釈" ? [sense] : findNodes(content(sense)) { value, _ in name(value) == "語釈" }
                return itemsFromNodes(glosses.map(englishHalf)).items
            }
        }
        var items: [String] = []
        for list in findNodes(parsed, isList) {
            let (listItems, found) = itemsFromList(list)
            items += listItems
            if found { return items }
        }
        return items + itemsFromNodes(fallbackNodes(parsed)).items
    }

    // MARK: Leading image

    enum Leading { case none, text, image(String) }

    /// The first meaningful token: an image (shown as a 36 px thumbnail) or anything else.
    static func leadingImage(_ root: Any?) -> Leading {
        var nodes = 0
        var result = Leading.none
        func walk(_ value: Any?) -> Bool {
            guard nodes < maxNodes else {
                result = .text
                return true
            }
            nodes += 1
            if let array = value as? [Any] {
                for child in array where walk(child) { return true }
                return false
            }
            guard let object = record(value) else {
                if let value, !(value is NSNull), String(describing: value).contains(where: { !$0.isWhitespace }) {
                    result = .text
                    return true
                }
                return false
            }
            if isIgnoredSection(object) { return false }
            let tag = tag(object)
            if tag == "img" {
                result = (object["path"] as? String).map(Leading.image) ?? .text
                return true
            }
            if tag == "br" || ignoredTags.contains(tag) { return false }
            return walk(content(object))
        }
        _ = walk(root)
        return result
    }
}
