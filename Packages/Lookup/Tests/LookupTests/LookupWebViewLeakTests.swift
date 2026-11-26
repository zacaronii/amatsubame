@testable import Lookup
import Testing
import WebKit

/// A closed popup's coordinator (and with it the popup's results and page) isn't kept alive by the
/// web view's content controller, which holds its script message handlers strongly.
@MainActor @Suite struct LookupWebViewLeakTests {
    @Test func theContentControllerDoesntKeepTheCoordinator() {
        let controller = WKUserContentController()
        weak var released: LookupWebView.Coordinator?
        do {
            let coordinator = LookupWebView.Coordinator(onEvent: { _ in })
            released = coordinator
            controller.add(WeakScriptMessageHandler(coordinator), name: "lookup")
            #expect(released != nil)
        }
        #expect(released == nil, "the coordinator went with its popup")
    }

    @Test func dismantlingRemovesTheHandler() {
        let configuration = WKWebViewConfiguration()
        let coordinator = LookupWebView.Coordinator(onEvent: { _ in })
        let proxy = WeakScriptMessageHandler(coordinator)
        configuration.userContentController.add(proxy, name: "lookup")
        let webView = WKWebView(frame: .zero, configuration: configuration)
        weak var weakProxy = proxy
        LookupWebView.dismantle(webView)
        _ = consume proxy
        #expect(weakProxy == nil, "the content controller let go of its handler")
    }
}
