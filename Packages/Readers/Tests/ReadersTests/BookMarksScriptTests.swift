#if os(macOS)
import Foundation
import Lookup
@testable import Readers
import Testing
import WebKit

/// BookReader.js's highlights, run in a web view on a made-up page: Kavita keeps a highlight as
/// the elements it starts and ends in and its text, and the reader finds the characters again.
@MainActor @Suite struct BookMarksScriptTests {
    final class Loaded: NSObject, WKNavigationDelegate {
        var done = false
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done = true }
    }

    func page() async throws -> WKWebView {
        let html = """
            <html><head><meta charset="utf-8"></head><body>
            <p>今日は<ruby>天気<rt>てんき</rt></ruby>がいい。散歩に<km-w class="km-new">行こう</km-w>か。</p>
            <p id="second">次の段落です。終わり。</p>
            <script>\(LookupPage.tapBridgeScript)</script>
            <script>\(BookWebController.resource("BookReader", "js"))</script>
            </body></html>
            """
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        let loaded = Loaded()
        view.navigationDelegate = loaded
        view.loadHTMLString(html, baseURL: nil)
        while !loaded.done { try await Task.sleep(for: .milliseconds(20)) }
        return view
    }

    func js(_ view: WKWebView, _ script: String) async throws -> Any? {
        try await view.evaluateJavaScript(script)
    }

    func shown(_ view: WKWebView, _ marks: String) async throws -> [Int] {
        try #require(try await js(view, "window.bookReader.marks.show(\(marks))") as? [Int])
    }

    func highlighted(_ view: WKWebView) async throws -> String {
        try await js(view, "[...document.querySelectorAll('km-hl')].map((m) => m.textContent).join('|')") as? String ?? ""
    }

    @Test func aHighlightIsFoundByItsTextWithoutTheFurigana() async throws {
        let view = try await page()
        #expect(try await shown(view, #"[{id: 1, xpath: "//body/p[1]", endXPath: "//body/p[1]", text: "天気がいい", color: "red"}]"#) == [1])
        #expect(try await highlighted(view) == "天気|がいい", "the furigana stays out")
    }

    @Test func overTwoParagraphsAndByIdAndNotFound() async throws {
        let view = try await page()
        let ids = try await shown(view, """
            [{id: 1, xpath: "//body/p[1]", endXPath: 'id("second")', text: "か。次の", color: "red"},
             {id: 2, xpath: 'id("second")', endXPath: 'id("second")', text: "終わり", color: "red"},
             {id: 3, xpath: "//body/p[1]", endXPath: "//body/p[1]", text: "載っていない", color: "red"}]
            """)
        #expect(ids == [1, 2], "a highlight whose text isn't there isn't drawn")
        #expect(try await highlighted(view) == "か。|次の|終わり")
    }

    @Test func highlightsStayWhenTheWordMarksChange() async throws {
        let view = try await page()
        _ = try await shown(view, #"[{id: 4, xpath: "//body/p[1]", endXPath: "//body/p[1]", text: "散歩に行こう", color: "red"}]"#)
        _ = try await js(view, "window.bookReader.unmarkWords(); true")
        #expect(try await highlighted(view).replacingOccurrences(of: "|", with: "") == "散歩に行こう")
        #expect(try await js(view, "document.querySelectorAll('km-w').length") as? Int == 0)
    }

    /// The centre of character `index` of the first text node in `selector`, as a JS expression.
    func point(_ selector: String, _ index: Int) -> String {
        """
        (() => { const t = document.querySelector('\(selector)').firstChild; const r = document.createRange();
          r.setStart(t, \(index)); r.setEnd(t, \(index) + 1); const b = r.getBoundingClientRect();
          return [b.left + b.width / 2, b.top + b.height / 2]; })()
        """
    }

    @Test func theTappedSentenceIsKeptAsKavitaWould() async throws {
        let view = try await page()
        // A tap on 行 (inside a word mark): its sentence, from the element it's in past the mark.
        let place = try #require(try await js(view, "window.bookReader.marks.sentenceAt(...\(point("km-w", 0)))") as? [String: Any])
        #expect(place["text"] as? String == "散歩に行こうか。")
        #expect(place["xpath"] as? String == "//body/p[1]" && place["endXPath"] as? String == "//body/p[1]")
        // Drawn again from what was kept, it's the same characters.
        _ = try await shown(view, #"[{id: 5, xpath: "//body/p[1]", endXPath: "//body/p[1]", text: "散歩に行こうか。", color: "red"}]"#)
        #expect(try await highlighted(view).replacingOccurrences(of: "|", with: "") == "散歩に行こうか。")
        // A tap inside it names the highlight.
        #expect(try await js(view, "window.bookReader.marks.markAt(...\(point("km-hl", 0)))") as? String == "5")
        #expect(try await js(view, "window.bookReader.marks.markAt(...\(point("#second", 1)))") is NSNull, "none elsewhere")
    }

    @Test func theFirstSentenceStartsAtTheParagraph() async throws {
        let view = try await page()
        let place = try #require(try await js(view, "window.bookReader.marks.sentenceAt(...\(point("#second", 2)))") as? [String: Any])
        #expect(place["text"] as? String == "次の段落です。")
        #expect(place["xpath"] as? String == #"id("second")"#)
    }

    /// The way the app loads a section: an XHTML file through the book scheme, the scripts
    /// injected. The sentence at a tap is found there too.
    @Test func inAnXHTMLSectionToo() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "book-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml"><head><title>t</title></head>
            <body><p id="second">次の段落です。終わり。</p></body></html>
            """.utf8).write(to: folder.appending(path: "s.xhtml"))
        let controller = BookWebController(folder: folder)
        controller.webView.frame = CGRect(x: 0, y: 0, width: 600, height: 400)
        let url = try #require(BookSchemeHandler.url(chapterId: 1, path: "s.xhtml"))
        #expect(await controller.loadAndWait(url))
        let place = try await controller.webView.evaluateJavaScript("window.bookReader.marks.sentenceAt(...\(point("#second", 8)))") as? [String: Any]
        #expect(place?["text"] as? String == "終わり。")
    }
}
#endif
