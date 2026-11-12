import Lookup
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// Serves `kavitabook://<chapterId>/<path>` from the unpacked book, so the book's
/// relative links, pictures and stylesheets load as they would from a file.
final class BookSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "kavitabook"
    let folder: URL

    init(folder: URL) {
        self.folder = folder.standardizedFileURL
    }

    static func url(chapterId: Int, path: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = String(chapterId)
        components.path = "/" + path
        return components.url
    }

    /// The file for a request, refusing anything outside the book's folder.
    func file(for url: URL) -> URL? {
        let path = (URLComponents(url: url, resolvingAgainstBaseURL: false)?.path ?? "").removingPercentEncoding ?? ""
        let file = folder.appending(path: String(path.drop(while: { $0 == "/" }))).standardizedFileURL
        guard file.path(percentEncoded: false).hasPrefix(folder.path(percentEncoded: false)) else { return nil }
        return file
    }

    static func mimeType(_ file: URL) -> String {
        switch file.pathExtension.lowercased() {
        case "xhtml", "xht": "application/xhtml+xml"
        case "html", "htm": "text/html"
        case "css": "text/css"
        case "svg": "image/svg+xml"
        case "ttf": "font/ttf"
        case "otf": "font/otf"
        case "woff": "font/woff"
        case "woff2": "font/woff2"
        default: UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        }
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url, let file = file(for: url), let data = try? Data(contentsOf: file) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let mime = Self.mimeType(file)
        let text = mime.hasPrefix("text/") || mime.contains("xml")
        task.didReceive(URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: text ? "utf-8" : nil))
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}

/// Messages from the book page's scripts.
enum BookWebEvent: Equatable {
    /// The page shown changed: index and count within this section, and the position as Kavita's XPath.
    case position(page: Int, pages: Int, xpath: String, vertical: Bool, characters: Int, sectionCharacters: Int, moved: Bool)
    /// Paging went past the start or end of the section.
    case edge(forward: Bool)
    /// A character was tapped: its block's text, the character's offset, and where it is.
    case tap(text: String, offset: Int, rect: CGRect)
    /// A tap that hit no text, in page coordinates.
    case miss(CGPoint)
    /// A horizontal swipe; `right` is the direction the fingers moved.
    case swipe(right: Bool)
    /// The scrolling layout was scrolled by hand (a finger, wheel or key), not by the reader.
    case userScrolled
    /// A link to another part of the book (table of contents pages, notes).
    case link(path: String, fragment: String?)
    case ready
    case failed(String)
}

/// Owns the web view so the model can load sections and call the page's scripts.
@MainActor
final class BookWebController: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    let webView: WKWebView
    var onEvent: (BookWebEvent) -> Void = { _ in }
    /// The section loading: its settings and place, given to the reader once it has loaded.
    private var pendingOpen: (settings: [String: Any], position: String)?
    /// A load awaited without the reader's layout (read-along reads the text this way).
    private var loading: CheckedContinuation<Bool, Never>?

    init(folder: URL) {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(BookSchemeHandler(folder: folder), forURLScheme: BookSchemeHandler.scheme)
        let content = configuration.userContentController
        let style = Self.resource("book", "css")
        // Books rarely set a viewport, and WebKit would then lay them out 980 px wide.
        let injectStyle = "(() => { const head = document.head || document.documentElement; "
            + "document.querySelectorAll('meta[name=viewport]').forEach((m) => m.remove()); "
            + "const v = document.createElement('meta'); v.name = 'viewport'; "
            + "v.content = 'width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no'; head.appendChild(v); "
            + "const s = document.createElement('style'); s.id = 'kb-style'; s.textContent = \(Self.jsString(style)); "
            + "head.appendChild(s); })();"
        // Hidden until BookReader.js has laid out and positioned the section.
        content.addUserScript(WKUserScript(source: "document.documentElement.style.opacity = '0';", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        content.addUserScript(WKUserScript(source: injectStyle, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        content.addUserScript(WKUserScript(source: LookupPage.tapBridgeScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        content.addUserScript(WKUserScript(source: Self.resource("BookReader", "js"), injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        content.add(WeakHandler(self), name: "book")
        content.add(WeakHandler(self), name: "lookup")
        webView.navigationDelegate = self
        webView.isInspectable = true
        #if os(iOS)
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.bounces = false
        webView.isOpaque = false
        webView.backgroundColor = .clear
        for direction in [UISwipeGestureRecognizer.Direction.left, .right] {
            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(swiped(_:)))
            swipe.direction = direction
            swipe.delegate = self
            webView.addGestureRecognizer(swipe)
        }
        #else
        webView.setValue(false, forKey: "drawsBackground")
        #endif
    }

    /// Paged books turn with swipes, so the page itself mustn't scroll under the finger.
    func setScrollEnabled(_ enabled: Bool) {
        #if os(iOS)
        webView.scrollView.isScrollEnabled = enabled
        #endif
    }

    #if os(iOS)
    @objc private func swiped(_ recognizer: UISwipeGestureRecognizer) {
        onEvent(.swipe(right: recognizer.direction == .right))
    }
    #endif

    /// Loads a section and positions it once laid out. `at` is a JS value: 'start', 'end', {xpath}, {fragment}.
    func load(_ url: URL, settings: [String: Any], at position: String) {
        pendingOpen = (settings, position)
        webView.load(URLRequest(url: url))
    }

    /// Loads a section without opening it in the reader; true once it has finished loading.
    func loadAndWait(_ url: URL) async -> Bool {
        loading?.resume(returning: false)
        return await withCheckedContinuation { continuation in
            loading = continuation
            webView.load(URLRequest(url: url))
        }
    }

    private func finishWaiting(_ loaded: Bool) -> Bool {
        guard let loading else { return false }
        self.loading = nil
        loading.resume(returning: loaded)
        return true
    }

    func run(_ script: String) {
        // `void`: some calls return promises, which evaluateJavaScript can't hand back.
        webView.evaluateJavaScript("void (\(script))", completionHandler: nil)
    }

    func evaluate(_ script: String) async -> Any? {
        try? await webView.evaluateJavaScript(script)
    }

    func update(settings: [String: Any]) {
        // Mid-load the page has no reader yet: it opens with these instead.
        if pendingOpen != nil {
            pendingOpen?.settings = settings
            return
        }
        run("window.bookReader?.update(\(Self.json(settings)))")
    }

    func highlight(offset: Int, length: Int) {
        run("window.lookupBridge?.highlight(\(offset), \(length))")
    }

    func clearHighlight() {
        run("window.lookupBridge?.clearHighlight()")
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if finishWaiting(true) { return }
        if let open = pendingOpen {
            pendingOpen = nil
            run("window.bookReader?.open(\(Self.json(open.settings)), \(open.position))")
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        if finishWaiting(false) { return }
        onEvent(.failed(error.localizedDescription))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        if finishWaiting(false) { return }
        onEvent(.failed(error.localizedDescription))
    }

    /// Links inside the book stay in the reader; web links open in the browser.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = action.request.url else { return .cancel }
        if url.scheme == BookSchemeHandler.scheme {
            guard action.navigationType == .linkActivated else { return .allow }
            let path = String((URLComponents(url: url, resolvingAgainstBaseURL: false)?.path ?? "").drop(while: { $0 == "/" }))
            onEvent(.link(path: path.removingPercentEncoding ?? path, fragment: url.fragment))
            return .cancel
        }
        if action.navigationType == .linkActivated {
            #if os(iOS)
            await UIApplication.shared.open(url)
            #else
            NSWorkspace.shared.open(url)
            #endif
        }
        return .cancel
    }

    // MARK: WKScriptMessageHandler

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let kind = body["kind"] as? String else { return }
        func number(_ key: String) -> Double { (body[key] as? NSNumber)?.doubleValue ?? 0 }
        switch kind {
        case "position":
            onEvent(.position(page: Int(number("page")), pages: Int(number("pages")), xpath: body["xpath"] as? String ?? "",
                              vertical: body["vertical"] as? Bool ?? true, characters: Int(number("characters")),
                              sectionCharacters: Int(number("total")), moved: body["moved"] as? Bool ?? false))
        case "edge":
            onEvent(.edge(forward: body["direction"] as? String == "next"))
        case "tap":
            guard let text = body["text"] as? String, let offset = body["offset"] as? Int else { return }
            let rect = body["rect"] as? [String: Any]
            func value(_ key: String) -> Double { (rect?[key] as? NSNumber)?.doubleValue ?? 0 }
            onEvent(.tap(text: text, offset: offset, rect: CGRect(x: value("x"), y: value("y"), width: value("width"), height: value("height"))))
        case "miss":
            onEvent(.miss(CGPoint(x: number("x"), y: number("y"))))
        case "userScroll":
            onEvent(.userScrolled)
        case "ready":
            onEvent(.ready)
        default:
            break
        }
    }

    // MARK: Helpers

    nonisolated static func resource(_ name: String, _ ext: String) -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Web") else { return "" }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    nonisolated static func json(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }

    nonisolated static func jsString(_ text: String) -> String { json(text) }

    /// WKUserContentController retains its handlers; this breaks the cycle.
    private final class WeakHandler: NSObject, WKScriptMessageHandler {
        weak var target: BookWebController?
        init(_ target: BookWebController) { self.target = target }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            MainActor.assumeIsolated { target?.userContentController(controller, didReceive: message) }
        }
    }
}

/// Hosts the controller's web view in SwiftUI.
struct BookWebView {
    let controller: BookWebController
}

#if os(iOS)
extension BookWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { controller.webView }
    func updateUIView(_ webView: WKWebView, context: Context) {}
}
#else
extension BookWebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { controller.webView }
    func updateNSView(_ webView: WKWebView, context: Context) {}
}
#endif

#if os(iOS)
extension BookWebController: UIGestureRecognizerDelegate {
    nonisolated func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                                       shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}
#endif
