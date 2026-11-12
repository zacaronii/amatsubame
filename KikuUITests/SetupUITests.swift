import XCTest

/// Kiku's first-launch setup against a test account.
/// Needs `AUDIOBOOKSHELF_URL` and `TEST_ABS_*` in `.env` (with `TEST_ABS_LIBRARIES`, see
/// `TestAccounts.libraries`), and Yomu installed.
final class SetupUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testSetupWithPasswordAndReuse() throws {
        let values = try TestAccounts.require("AUDIOBOOKSHELF_URL", "TEST_ABS_USER", "TEST_ABS_PASSWORD")
        let libraries = try TestAccounts.libraries("TEST_ABS_LIBRARIES")
        let data = "kiku-\(UUID().uuidString.prefix(8))"
        try SharedSetupFixture.prepare(data: data)
        let app = XCUIApplication.setup(data: data)
        app.launch()
        app.buttons["setup.getStarted"].tap()

        XCTAssertTrue(app.waitForTitle("Connect Audiobookshelf"))
        // A wrong password first.
        app.type(values[0], into: "setup.server.url")
        app.type(values[1], into: "setup.server.username")
        app.type("wrong-password", into: "setup.server.password")
        app.buttons["setup.continue"].tap()
        sleep(5)
        XCTAssertEqual(app.buttons["setup.continue"].label, "Sign In", "a wrong password doesn't sign in")
        let password = app.element("setup.server.password")
        password.tap()
        password.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 20) + values[2])
        app.buttons["setup.continue"].tap()
        let connected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS 'libraries found'"),
                                                  object: app.element("setup.server.status"))
        XCTAssertEqual(XCTWaiter.wait(for: [connected], timeout: 30), .completed)
        app.tapContinue()

        XCTAssertTrue(app.waitForTitle("Which libraries are Japanese?"))
        let podcasts = app.switches["setup.library.\(libraries.japanese)"], english = app.switches["setup.library.\(libraries.english)"]
        XCTAssertTrue(podcasts.waitForExistence(timeout: 30))
        XCTAssertEqual(podcasts.value as? String, "1")
        XCTAssertEqual(english.value as? String, "0")
        app.tapContinue()

        XCTAssertTrue(app.waitForTitle("Use your existing setup?"))
        app.buttons["setup.continue"].tap()
        XCTAssertTrue(app.waitForTitle("Extras"))
        XCTAssertTrue(app.element("setup.extra.Kaku").label.contains("Recommended"))
        app.element("setup.extra.Kaku").tap()
        XCTAssertTrue(app.navigationBars.buttons.firstMatch.waitForExistence(timeout: 10))
        app.navigationBars.buttons.firstMatch.tap()
        app.tapContinue()
        XCTAssertTrue(app.staticTexts["setup.done"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.element("setup.checklist.Kaku transcripts").label.contains("Settings → Listening"))
        app.buttons["setup.start"].tap()
    }
}
