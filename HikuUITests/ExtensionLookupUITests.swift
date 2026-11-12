import Network
import XCTest

/// Turns on the Safari extension in the simulator's Settings, opens a Japanese page in Safari
/// (served by the test) and taps a word. Uses the dictionaries bundled into dev builds.
final class ExtensionLookupUITests: XCTestCase {
    static let page = """
    <!doctype html><html lang="ja"><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1"><title>Test</title></head>
    <body style="font-size: 28px; margin: 40px 20px;">
    <p id="english">OK English words</p>
    <p id="text">昨日は寿司を食べました。とても美味しかったです。</p>
    <p><a href="#elsewhere">リンクの言葉</a></p>
    </body></html>
    """

    var server: TestServer?

    override func tearDown() {
        server?.stop()
    }

    func testTappingAWordShowsThePopup() throws {
        // Safari only lists an extension once its app has been opened.
        XCUIApplication().launch()
        enableExtension()

        server = try TestServer(html: Self.page)
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        safari.terminate()
        XCUIDevice.shared.system.open(try XCTUnwrap(URL(string: "http://127.0.0.1:\(server!.port)/")))
        XCTAssertTrue(safari.wait(for: .runningForeground, timeout: 10))
        allowOnThisSite(safari)
        let text = safari.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS '寿司を食べました'")).firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 15), "the page loaded")

        // Japanese text only (on by default): a tap on English never reaches the dictionaries.
        // "OK" is a word in Jitendex, so it would show a popup otherwise.
        let english = safari.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS 'English words'")).firstMatch
        XCTAssertTrue(english.exists)
        let ok = english.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 10, dy: english.frame.height / 2))
        ok.tap()
        let anyPopup = safari.webViews.buttons["Add to Anki"].firstMatch
        XCTAssertFalse(anyPopup.waitForExistence(timeout: 90), "a tap on English text looks nothing up")

        // 食 is the 7th character of the line (after 昨日は寿司を).
        let frame = text.frame
        let characterWidth = frame.width / CGFloat("昨日は寿司を食べました。".count)
        text.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: characterWidth * 6.5, dy: characterWidth * 0.6)).tap()

        // The first lookup imports the dictionaries.
        let gloss = safari.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'to eat'")).firstMatch
        let found = gloss.waitForExistence(timeout: 180)
        attach(safari.screenshot(), "after tap")
        if !found { print("=== SAFARI\n", safari.debugDescription) }
        XCTAssertTrue(found, "the popup shows 食べる")

        attach(safari.screenshot(), "word marks")

        // A tap on English closes the popup, like a tap on empty space (the line is above
        // the word, so the popup below doesn't cover it).
        ok.tap()
        XCTAssertTrue(gloss.waitForNonExistence(timeout: 5), "the popup closes")
        text.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: characterWidth * 6.5, dy: characterWidth * 0.6)).tap()
        XCTAssertTrue(gloss.waitForExistence(timeout: 15), "食 still looks up")

        // With the popup open, a tap on another word only closes it; the next one looks up.
        // From the screen, not the line: the highlight splits the line into several texts.
        let sushiAt = safari.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: frame.minX + characterWidth * 3.5, dy: frame.minY + characterWidth * 0.6))
        let sushi = safari.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'sushi'")).firstMatch
        sushiAt.tap()
        XCTAssertTrue(gloss.waitForNonExistence(timeout: 5), "the popup closes")
        XCTAssertFalse(sushi.waitForExistence(timeout: 5), "and 寿司 isn't looked up")
        sushiAt.tap()
        XCTAssertTrue(sushi.waitForExistence(timeout: 15), "the next tap looks 寿司 up")

        // Add to Anki goes through to the native side; without AnkiConnect set up it says where to set it.
        let mine = safari.webViews.buttons["Add to Anki"].firstMatch
        XCTAssertTrue(mine.waitForExistence(timeout: 5))
        mine.tap()
        let note = safari.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS 'AnkiConnect'")).firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 15), "the popup explains AnkiConnect isn't set up")
        attach(safari.screenshot(), "after mine")
    }

    /// Only turns the extension on, for a simulator set up for hands-on testing
    /// (`TEST_RUNNER_UITEST_ENABLE_EXTENSION_ONLY=1`; nothing is looked up or mined).
    func testEnableExtensionOnly() throws {
        guard ProcessInfo.processInfo.environment["UITEST_ENABLE_EXTENSION_ONLY"] != nil else {
            throw XCTSkip("Set TEST_RUNNER_UITEST_ENABLE_EXTENSION_ONLY=1 to only turn the extension on.")
        }
        XCUIApplication().launch()
        enableExtension()
    }

    private func attach(_ screenshot: XCUIScreenshot, _ name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Settings → Apps → Safari → Extensions → Hiku → Allow Extension.
    private func enableExtension() {
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.terminate()
        settings.launch()
        let apps = settings.buttons["com.apple.settings.apps"].firstMatch
        for _ in 0..<8 where !apps.isHittable { settings.swipeUp() }
        apps.tap()
        let safari = settings.buttons["com.apple.mobilesafari"].firstMatch
        for _ in 0..<15 where !safari.isHittable { settings.swipeUp() }
        safari.tap()
        let extensions = settings.cells["WEB_EXTENSIONS"].firstMatch
        for _ in 0..<10 where !extensions.isHittable { settings.swipeUp() }
        extensions.tap()
        settings.buttons["com.amatsubame.hiku.extension"].firstMatch.tap()
        let allow = settings.switches["Allow Extension"].firstMatch
        XCTAssertTrue(allow.waitForExistence(timeout: 5))
        if allow.value as? String != "1" { allow.switches.firstMatch.exists ? allow.switches.firstMatch.tap() : allow.tap() }
        sleep(1)
        print("=== EXTENSION SETTINGS\n", settings.debugDescription)
        // Website access: allow on every site, when Settings offers it.
        let allSites = settings.buttons["All Websites"].firstMatch
        for _ in 0..<5 where !allSites.isHittable { settings.swipeUp() }
        if allSites.exists, !(allSites.label.hasSuffix("Allow")) {
            allSites.tap()
            sleep(1)
            print("=== ALL WEBSITES\n", settings.debugDescription)
            let allowOption = settings.descendants(matching: .any).matching(NSPredicate(format: "label == 'Allow'")).firstMatch
            if allowOption.waitForExistence(timeout: 3) { allowOption.tap() }
        }
        settings.terminate()
    }

    /// Safari may ask once whether the extension may read this site.
    private func allowOnThisSite(_ safari: XCUIApplication) {
        let always = safari.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Always Allow'")).firstMatch
        if always.waitForExistence(timeout: 4) {
            always.tap()
            let everywhere = safari.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Every Website'")).firstMatch
            if everywhere.waitForExistence(timeout: 3) { everywhere.tap() }
        }
    }
}

/// A one-page HTTP server on 127.0.0.1 (the simulator shares the Mac's network).
final class TestServer: @unchecked Sendable {
    let listener: NWListener
    let port: UInt16

    init(html: String) throws {
        let body = Data(html.utf8)
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { _, _, _, _ in
                let head = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in if case .ready = state { ready.signal() } }
        listener.start(queue: .global())
        _ = ready.wait(timeout: .now() + 5)
        port = listener.port?.rawValue ?? 0
    }

    func stop() {
        listener.cancel()
    }
}
