#if os(macOS)
import AppKit
import Foundation
import Testing
import WebKit
@testable import Lookup

/// TextTapBridge.js's Look Up on Hover, run in a web view: the pointer resting on a word looks
/// it up when the chosen key is held (or none is needed), and never reports a miss.
@MainActor @Suite struct HoverBridgeTests {
    final class Loaded: NSObject, WKNavigationDelegate {
        var done = false
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done = true }
    }

    /// A page with one paragraph, the bridge, and its messages collected in `window.posted`.
    func page() async throws -> WKWebView {
        let html = """
            <html><head><meta charset="utf-8"><style>body { margin: 0; font: 40px/60px sans-serif; }</style></head>
            <body><p id="p" style="margin: 0">猫が、食べる</p>
            <script>window.posted = []; window.lookupBridgePost = (message) => window.posted.push(message);</script>
            <script>\(LookupPage.tapBridgeScript)</script></body></html>
            """
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 600, height: 300))
        let loaded = Loaded()
        view.navigationDelegate = loaded
        view.loadHTMLString(html, baseURL: nil)
        while !loaded.done { try await Task.sleep(for: .milliseconds(20)) }
        return view
    }

    /// Moves the pointer onto the character at `index` of the paragraph (or the empty space
    /// below the text when nil), waits past the rest, and returns what was posted since.
    func hover(_ view: WKWebView, character index: Int?, shift: Bool = false) async throws -> [[String: Any]] {
        let point = index.map { """
            (() => { const r = document.createRange(); const t = document.getElementById('p').firstChild;
              r.setStart(t, \($0)); r.setEnd(t, \($0) + 1); const b = r.getBoundingClientRect();
              return {x: b.left + b.width / 2, y: b.top + b.height / 2}; })()
            """ } ?? "({x: 300, y: 250})"
        _ = try await view.evaluateJavaScript("""
            (() => { window.posted = []; const at = \(point);
              document.dispatchEvent(new MouseEvent('mousemove', {clientX: at.x, clientY: at.y, shiftKey: \(shift), bubbles: true})); return true; })()
            """)
        try await Task.sleep(for: .milliseconds(350))
        return try #require(try await view.evaluateJavaScript("window.posted") as? [[String: Any]])
    }

    @Test func offUntilTheHostTurnsItOn() async throws {
        let view = try await page()
        #expect(try await hover(view, character: 0, shift: true).isEmpty)
    }

    @Test func theKeyMustBeHeld() async throws {
        let view = try await page()
        _ = try await view.evaluateJavaScript("window.lookupBridge.setHover('shift'); true")
        #expect(try await hover(view, character: 3).isEmpty, "no key, no lookup")
        let posted = try await hover(view, character: 3, shift: true)
        #expect(posted.count == 1)
        #expect(posted.first?["kind"] as? String == "tap")
        #expect(posted.first?["text"] as? String == "猫が、食べる" && posted.first?["offset"] as? Int == 3)
    }

    @Test func withoutAKeyRestingIsEnoughButNeverAMissOrPunctuation() async throws {
        let view = try await page()
        _ = try await view.evaluateJavaScript("window.lookupBridge.setHover('always'); true")
        #expect(try await hover(view, character: 0).first?["offset"] as? Int == 0)
        #expect(try await hover(view, character: 2).isEmpty, "the comma looks nothing up")
        #expect(try await hover(view, character: nil).isEmpty, "empty space isn't a miss (a miss turns the page)")
    }
}
#endif
