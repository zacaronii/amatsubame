#if os(macOS)
import AppKit
import Core
import Dictionary
import Foundation
@testable import Lookup
import Testing
import WebKit

/// Renders the popup for real dictionaries to PNGs, to check its layout by eye:
/// `REAL_DICTIONARY_ZIPS="<zip>|…" POPUP_RENDER_DIR=<folder> swift test --filter RealPopupRenderTests`.
@MainActor @Suite(.enabled(if: ProcessInfo.processInfo.environment["POPUP_RENDER_DIR"] != nil))
struct RealPopupRenderTests {
    @Test func rendersSampleWords() async throws {
        let env = ProcessInfo.processInfo.environment
        let folder = URL(filePath: try #require(env["POPUP_RENDER_DIR"]))
        let library = DictionaryLibrary(database: try AppDatabase.inMemory(),
                                        directory: FileManager.default.temporaryDirectory.appending(path: "popup-\(UUID().uuidString)"))
        for path in (env["REAL_DICTIONARY_ZIPS"] ?? "").split(separator: "|") {
            _ = try await library.importDictionary(at: URL(filePath: String(path)))
        }
        try await library.reloadEngine()
        let styles = await library.engine.styles()
        let samples: [(name: String, text: String, sentence: String?)] = [
            ("nande", "なんでんな遅くまで起きてるんです？", "なんでんな遅くまで起きてるんです？"),
            ("machini", "待ちに待った", nil), ("nihongo", "日本語", nil), ("taberu", "食べさせられなかった", nil),
        ]
        for sample in samples {
            let results = await library.engine.lookup(String(sample.text.prefix(16)))
            let source = sample.sentence.map {
                EntryRenderer.source(LookupSource(text: $0, utf16Offset: 0, utf16Length: results.first?.matched.utf16.count ?? 0))
            } ?? ""
            let html = LookupPage.document(body: source + EntryRenderer.entries(Array(results.prefix(2)), mined: results.prefix(2).map { _ in false }),
                                           dictionaryStyles: styles, extraCSS: ":root { --accent: #3FC98F; --on-accent: #04261A; }")
            try html.write(to: folder.appending(path: "\(sample.name).html"), atomically: true, encoding: .utf8)
            try await Self.snapshot(html, to: folder.appending(path: "\(sample.name).png"))
        }
    }

    static func snapshot(_ html: String, to file: URL) async throws {
        let height = ProcessInfo.processInfo.environment["POPUP_RENDER_HEIGHT"].flatMap(Double.init) ?? 1400
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: height))
        view.appearance = NSAppearance(named: .darkAqua)
        let loaded = Loaded()
        view.navigationDelegate = loaded
        view.loadHTMLString(html, baseURL: nil)
        while !loaded.done { try await Task.sleep(for: .milliseconds(50)) }
        try await Task.sleep(for: .milliseconds(300))
        let image = try await view.takeSnapshot(configuration: nil)
        let bitmap = NSBitmapImageRep(data: try #require(image.tiffRepresentation))
        try #require(bitmap?.representation(using: .png, properties: [:])).write(to: file)
    }

    final class Loaded: NSObject, WKNavigationDelegate {
        var done = false
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done = true }
    }
}
#endif
