import XCTest

/// The public demo servers for UI tests, read from their published config.json: one source,
/// since the password is reset there. Tests skip while it can't be reached.
enum DemoServers {
    static let address = URL(string: "https://demo.amatsubame.com/config.json")!

    private struct Config: Decodable {
        struct Kavita: Decodable { let url: String; let apiKey: String }
        struct SignIn: Decodable { let url: String; let user: String; let password: String }
        let kavita: Kavita?
        let jellyfin: SignIn?
        let audiobookshelf: SignIn?
    }

    private static func config() throws -> Config {
        guard let data = try? Data(contentsOf: address), let config = try? JSONDecoder().decode(Config.self, from: data) else {
            throw XCTSkip("The demo servers' config.json (\(address.absoluteString)) can't be read.")
        }
        return config
    }

    /// Kavita's address and API key.
    static func kavita() throws -> [String] {
        guard let kavita = try config().kavita else { throw XCTSkip("The demo has no Kavita.") }
        return [kavita.url, kavita.apiKey]
    }

    /// Jellyfin's address, user and password.
    static func jellyfin() throws -> [String] {
        guard let jellyfin = try config().jellyfin else { throw XCTSkip("The demo has no Jellyfin.") }
        return [jellyfin.url, jellyfin.user, jellyfin.password]
    }

    /// Audiobookshelf's address, user and password.
    static func audiobookshelf() throws -> [String] {
        guard let abs = try config().audiobookshelf else { throw XCTSkip("The demo has no Audiobookshelf.") }
        return [abs.url, abs.user, abs.password]
    }
}

extension XCTestCase {
    /// Try It with the Demo Servers, offline-safe: `DEMO_CONFIG` points at made-up servers that
    /// can't be reached, then at no file at all. The server step shows the demo card (no address
    /// to type) and the failure, and Use My Own Server Instead brings the fields back; without a
    /// config, the button says the demo isn't available.
    func checkDemoButton(_ app: XCUIApplication, server: String) {
        let unreachable = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "demo-unreachable.json")
        app.launchEnvironment["DEMO_CONFIG"] = unreachable.path(percentEncoded: false)
        app.launch()
        let demo = app.buttons["setup.demo"]
        XCTAssertTrue(demo.waitForExistence(timeout: 20), "Welcome offers the demo")
        demo.tap()
        XCTAssertTrue(app.waitForTitle(server), "the server step")
        XCTAssertTrue(app.element("setup.demo.card").waitForExistence(timeout: 10), "a demo card instead of fields")
        XCTAssertFalse(app.element("setup.server.url").exists)
        let failed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != ''"), object: app.element("setup.server.status"))
        XCTAssertEqual(XCTWaiter.wait(for: [failed], timeout: 60), .completed, "it tried, and says it couldn't")
        keepScreenshot(app, "demo-unreachable")
        app.buttons["setup.demo.ownServer"].tap()
        XCTAssertTrue(app.element("setup.server.url").waitForExistence(timeout: 5), "your own server's fields are back")
        XCTAssertFalse(app.element("setup.demo.card").exists)
        app.terminate()

        // A first launch again (setup would resume at the server step).
        app.launchEnvironment["UITEST_SETUP_DATA"] = (app.launchEnvironment["UITEST_SETUP_DATA"] ?? "demo") + "-none"
        app.launchEnvironment["DEMO_CONFIG"] = "/nonexistent/demo.json"
        app.launch()
        XCTAssertTrue(demo.waitForExistence(timeout: 20))
        demo.tap()
        XCTAssertTrue(app.element("setup.demo.problem").waitForExistence(timeout: 10))
        XCTAssertTrue(app.element("setup.demo.problem").label.contains("isn't available"))
        XCTAssertTrue(app.buttons["setup.getStarted"].exists, "still on Welcome")
    }

    /// The real demo: signs in from the published config without typing anything, and goes on
    /// to the libraries step. Skips while config.json can't be read.
    func checkDemoSignIn(_ app: XCUIApplication, server: String) throws {
        guard (try? Data(contentsOf: DemoServers.address)) != nil else {
            throw XCTSkip("The demo servers' config.json can't be read yet.")
        }
        app.launch()
        app.buttons["setup.demo"].tap()
        XCTAssertTrue(app.waitForTitle(server))
        let connected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS 'found'"),
                                                  object: app.element("setup.server.status"))
        XCTAssertEqual(XCTWaiter.wait(for: [connected], timeout: 60), .completed, "signed in to the demo")
        keepScreenshot(app, "demo-signed-in")
        app.tapContinue()
        app.dismissSavePassword()
        XCTAssertTrue(app.waitForTitle("Which libraries are Japanese?"), "on to the libraries")
    }
}

extension XCTestCase {
    /// After trying the demo: Settings says the server is the demo, its page offers Use My Own
    /// Server…, and that signs out of the demo (the page's own fields come back). Live; skips
    /// while config.json can't be read.
    func checkDemoSettings(_ app: XCUIApplication, server: String, row: String) throws {
        try checkDemoSignIn(app, server: server)
        app.tapContinue()
        XCTAssertTrue(app.waitForTitle("Get dictionaries"))
        app.buttons["setup.dictionaries.skip"].tap()
        if app.waitForTitle("Connect Anki", timeout: 20) { app.buttons["setup.anki.skip"].tap() }
        if app.waitForTitle("Extras", timeout: 20) { app.tapContinue() }
        XCTAssertTrue(app.buttons["setup.start"].waitForExistence(timeout: 20))
        app.buttons["setup.start"].tap()
        sleep(2)
        app.tabBars.buttons["Settings"].tap()
        let serverRow = app.revealSettingsRow(row)
        XCTAssertTrue(serverRow.waitForExistence(timeout: 10))
        XCTAssertTrue(serverRow.label.contains("Demo server"), "the row says it's the demo: \(serverRow.label)")
        serverRow.tap()
        let section = app.descendants(matching: .any)["server.demo"].firstMatch
        XCTAssertTrue(section.waitForExistence(timeout: 10), "the page says it's the demo")
        keepScreenshot(app, "demo-settings")
        app.buttons["server.demo.ownServer"].tap()
        XCTAssertTrue(section.waitForNonExistence(timeout: 10), "signed out of the demo")
        XCTAssertTrue(app.textFields.firstMatch.waitForExistence(timeout: 5), "the page's own fields are back")
        keepScreenshot(app, "demo-left")
    }
}
