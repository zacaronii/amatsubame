import Foundation

/// What the reader needs from an unpacked EPUB: the reading order (Kavita's
/// page N is spine item N), the cover and the table of contents.
public struct EpubPackage: Equatable, Sendable {
    public struct SpineItem: Equatable, Sendable {
        /// Path inside the book folder, e.g. `text/part0003.xhtml`.
        public var path: String
        public var linear: Bool
    }

    public struct TOCEntry: Equatable, Sendable, Identifiable {
        public var id: String { "\(spineIndex)#\(fragment ?? "")|\(title)" }
        public var title: String
        public var spineIndex: Int
        public var fragment: String?
        public var depth: Int
    }

    public var title: String
    public var language: String?
    public var spine: [SpineItem]
    /// `rtl` for right-to-left page order (most Japanese books).
    public var pageProgressionRTL: Bool
    public var coverPath: String?
    public var toc: [TOCEntry]

    public enum ParseError: Error, Equatable, LocalizedError {
        case missingContainer
        case missingPackage(String)
        case emptySpine

        public var errorDescription: String? {
            switch self {
            case .missingContainer: "This EPUB has no META-INF/container.xml."
            case .missingPackage(let path): "This EPUB's package file (\(path)) is missing."
            case .emptySpine: "This EPUB has no pages."
            }
        }
    }

    /// Reads the unpacked book in `folder`.
    public static func parse(folder: URL) throws -> EpubPackage {
        guard let container = try? Data(contentsOf: folder.appending(path: "META-INF/container.xml")) else {
            throw ParseError.missingContainer
        }
        let containerDoc = XMLTree.parse(container)
        guard let opfPath = containerDoc?.first("rootfile")?.attributes["full-path"] else { throw ParseError.missingContainer }
        guard let opfData = try? Data(contentsOf: folder.appending(path: opfPath)), let opf = XMLTree.parse(opfData) else {
            throw ParseError.missingPackage(opfPath)
        }
        let base = (opfPath as NSString).deletingLastPathComponent

        var manifest: [String: (href: String, mediaType: String, properties: String)] = [:]
        for item in opf.all("item") {
            guard let id = item.attributes["id"], let href = item.attributes["href"] else { continue }
            manifest[id] = (resolve(href, base: base), item.attributes["media-type"] ?? "", item.attributes["properties"] ?? "")
        }
        let spineNode = opf.first("spine")
        let spine = (spineNode?.all("itemref") ?? []).compactMap { ref -> SpineItem? in
            guard let id = ref.attributes["idref"], let item = manifest[id] else { return nil }
            return SpineItem(path: item.href, linear: ref.attributes["linear"] != "no")
        }
        guard !spine.isEmpty else { throw ParseError.emptySpine }

        let coverId = opf.all("meta").first { $0.attributes["name"] == "cover" }?.attributes["content"]
        let cover = manifest.values.first { $0.properties.split(separator: " ").contains("cover-image") }?.href
            ?? coverId.flatMap { manifest[$0] }.flatMap { $0.mediaType.hasPrefix("image/") ? $0.href : nil }

        var toc: [TOCEntry] = []
        if let nav = manifest.values.first(where: { $0.properties.split(separator: " ").contains("nav") }),
           let data = try? Data(contentsOf: folder.appending(path: nav.href)), let doc = XMLTree.parse(data) {
            toc = navEntries(doc, navPath: nav.href, spine: spine)
        }
        if toc.isEmpty, let ncxId = spineNode?.attributes["toc"], let ncx = manifest[ncxId],
           let data = try? Data(contentsOf: folder.appending(path: ncx.href)), let doc = XMLTree.parse(data) {
            toc = ncxEntries(doc, ncxPath: ncx.href, spine: spine)
        }

        return EpubPackage(
            title: opf.first("title")?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            language: opf.first("language")?.text.trimmingCharacters(in: .whitespacesAndNewlines),
            spine: spine,
            pageProgressionRTL: spineNode?.attributes["page-progression-direction"] == "rtl",
            coverPath: cover,
            toc: toc
        )
    }

    /// `href` relative to the folder of `base`, percent-decoded and normalized (`a/../b` → `b`).
    static func resolve(_ href: String, base: String) -> String {
        let decoded = href.removingPercentEncoding ?? href
        var parts = base.isEmpty ? [] : base.split(separator: "/").map(String.init)
        for part in decoded.split(separator: "/", omittingEmptySubsequences: true).map(String.init) {
            switch part {
            case ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(part)
            }
        }
        return parts.joined(separator: "/")
    }

    static func entry(_ title: String, href: String, relativeTo docPath: String, depth: Int, spine: [SpineItem]) -> TOCEntry? {
        let pieces = href.split(separator: "#", maxSplits: 1).map(String.init)
        let path = resolve(pieces.first ?? "", base: (docPath as NSString).deletingLastPathComponent)
        guard let index = spine.firstIndex(where: { $0.path == path }) else { return nil }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return TOCEntry(title: title.isEmpty ? "Section \(index + 1)" : title, spineIndex: index,
                        fragment: pieces.count > 1 ? pieces[1] : nil, depth: depth)
    }

    /// EPUB 3: `<nav epub:type="toc"><ol><li><a href>…`.
    static func navEntries(_ doc: XMLTree, navPath: String, spine: [SpineItem]) -> [TOCEntry] {
        let navs = doc.all("nav")
        guard let nav = navs.first(where: { ($0.attributes["epub:type"] ?? $0.attributes["type"]) == "toc" }) ?? navs.first,
              let list = nav.first("ol") else { return [] }
        var entries: [TOCEntry] = []
        func walk(_ list: XMLTree, depth: Int) {
            for item in list.children where item.name == "li" {
                if let link = item.children.first(where: { $0.name == "a" }) ?? item.first("a"),
                   let href = link.attributes["href"],
                   let entry = entry(link.text, href: href, relativeTo: navPath, depth: depth, spine: spine) {
                    entries.append(entry)
                }
                if let nested = item.children.first(where: { $0.name == "ol" }) { walk(nested, depth: depth + 1) }
            }
        }
        walk(list, depth: 0)
        return entries
    }

    /// EPUB 2: `<navMap><navPoint><navLabel><text>…</text></navLabel><content src>`.
    static func ncxEntries(_ doc: XMLTree, ncxPath: String, spine: [SpineItem]) -> [TOCEntry] {
        guard let map = doc.first("navMap") else { return [] }
        var entries: [TOCEntry] = []
        func walk(_ node: XMLTree, depth: Int) {
            for point in node.children where point.name == "navPoint" {
                if let src = point.children.first(where: { $0.name == "content" })?.attributes["src"],
                   let entry = entry(point.first("text")?.text ?? "", href: src, relativeTo: ncxPath, depth: depth, spine: spine) {
                    entries.append(entry)
                }
                walk(point, depth: depth + 1)
            }
        }
        walk(map, depth: 0)
        return entries
    }
}

/// A small DOM over Foundation's XMLParser (namespace prefixes kept as written).
final class XMLTree {
    let name: String
    let attributes: [String: String]
    fileprivate(set) var children: [XMLTree] = []
    fileprivate var ownText = ""

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    /// All text inside, in document order.
    var text: String { ownText + children.map(\.text).joined() }

    /// Matches on the local name, so `dc:title` is found as `title`.
    private func matches(_ local: String) -> Bool {
        name == local || name.hasSuffix(":" + local)
    }

    func first(_ local: String) -> XMLTree? {
        for child in children {
            if child.matches(local) { return child }
            if let found = child.first(local) { return found }
        }
        return nil
    }

    func all(_ local: String) -> [XMLTree] {
        children.flatMap { ($0.matches(local) ? [$0] : []) + $0.all(local) }
    }

    static func parse(_ data: Data) -> XMLTree? {
        let delegate = Builder()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        _ = parser.parse()
        return delegate.root
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var root: XMLTree?
        var stack: [XMLTree] = []

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            let node = XMLTree(name: name, attributes: attributes)
            if let parent = stack.last { parent.children.append(node) } else { root = node }
            stack.append(node)
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            _ = stack.popLast()
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            stack.last?.ownText += string
        }
    }
}
