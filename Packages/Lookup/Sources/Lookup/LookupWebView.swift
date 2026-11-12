import Dictionary
import SwiftUI
import WebKit

/// Messages from the page's tap bridge.
public enum LookupWebEvent: Equatable, Sendable {
    /// A character was tapped: the block's text and the character's UTF-16 offset.
    case tap(text: String, offset: Int)
    /// An internal `?query=` link in a glossary.
    case query(String)
    case audio(index: Int)
    /// The Add to Anki button of a result.
    case mine(index: Int)
}

/// Serves `dictmedia://media/<path>?dictionary=<title>` from the dictionary engine.
final class DictionaryMediaHandler: NSObject, WKURLSchemeHandler {
    let engine: DictionaryEngine

    init(engine: DictionaryEngine) {
        self.engine = engine
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        let url = task.request.url
        let components = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        let dictionary = components?.queryItems?.first { $0.name == "dictionary" }?.value ?? ""
        let path = String((components?.path ?? "").dropFirst())
        let engine = engine
        let taskBox = UncheckedTask(task)
        Task { @MainActor in
            let data = await engine.mediaFile(dictionary: dictionary, path: path)
            guard let url, let data else {
                taskBox.task.didFailWithError(URLError(.fileDoesNotExist))
                return
            }
            let mime = Self.mimeType(path)
            taskBox.task.didReceive(URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: nil))
            taskBox.task.didReceive(data)
            taskBox.task.didFinish()
        }
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}

    static func mimeType(_ path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "svg": "image/svg+xml"
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "webp": "image/webp"
        case "avif": "image/avif"
        default: "application/octet-stream"
        }
    }

    /// WKURLSchemeTask isn't Sendable but must be completed on the main thread, which we do.
    struct UncheckedTask: @unchecked Sendable {
        let task: any WKURLSchemeTask
        init(_ task: any WKURLSchemeTask) { self.task = task }
    }
}

/// A WKWebView showing lookup HTML and reporting taps, links and audio buttons.
@MainActor
struct LookupWebView {
    let html: String
    let engine: DictionaryEngine
    /// Results mined since the page loaded; their buttons turn into checks without a reload.
    var minedIndices: Set<Int> = []
    let onEvent: (LookupWebEvent) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onEvent: onEvent) }

    func makeWebView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(DictionaryMediaHandler(engine: engine), forURLScheme: StructuredContentRenderer.mediaScheme)
        configuration.userContentController.add(context.coordinator, name: "lookup")
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        #if os(iOS)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.contentInsetAdjustmentBehavior = .automatic
        #else
        webView.setValue(false, forKey: "drawsBackground")
        #endif
        webView.isInspectable = true
        return webView
    }

    func update(_ webView: WKWebView, context: Context) {
        context.coordinator.onEvent = onEvent
        if context.coordinator.loadedHTML != html {
            context.coordinator.loadedHTML = html
            context.coordinator.markedMined = []
            webView.loadHTMLString(html, baseURL: URL(string: "about:blank"))
        }
        let newlyMined = minedIndices.subtracting(context.coordinator.markedMined)
        guard !newlyMined.isEmpty else { return }
        context.coordinator.markedMined.formUnion(newlyMined)
        // Before the page finishes loading this is a no-op, but the HTML already has the marks then.
        let selectors = newlyMined.map { ".mine-button[data-index=\"\($0)\"]" }.joined(separator: ",")
        webView.evaluateJavaScript("document.querySelectorAll('\(selectors)').forEach(b => b.classList.add('mined'))")
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var onEvent: (LookupWebEvent) -> Void
        var loadedHTML: String?
        var markedMined: Set<Int> = []

        init(onEvent: @escaping (LookupWebEvent) -> Void) {
            self.onEvent = onEvent
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let kind = body["kind"] as? String else { return }
            switch kind {
            case "tap":
                if let text = body["text"] as? String, let offset = body["offset"] as? Int {
                    onEvent(.tap(text: text, offset: offset))
                }
            case "query":
                if let query = body["query"] as? String { onEvent(.query(query)) }
            case "audio":
                if let index = body["index"] as? Int { onEvent(.audio(index: index)) }
            case "mine":
                if let index = body["index"] as? Int { onEvent(.mine(index: index)) }
            default:
                break
            }
        }

        /// External glossary links open in the system browser, never inside the popup.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard action.navigationType == .linkActivated, let url = action.request.url else { return .allow }
            #if os(iOS)
            await UIApplication.shared.open(url)
            #else
            NSWorkspace.shared.open(url)
            #endif
            return .cancel
        }
    }
}

#if os(iOS)
extension LookupWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { makeWebView(context: context) }
    func updateUIView(_ webView: WKWebView, context: Context) { update(webView, context: context) }
}
#else
extension LookupWebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { makeWebView(context: context) }
    func updateNSView(_ webView: WKWebView, context: Context) { update(webView, context: context) }
}
#endif
