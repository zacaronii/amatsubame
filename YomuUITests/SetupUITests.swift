import XCTest

/// First-launch setup against a test account. Each test
/// gets its own app data (`UITEST_SETUP_DATA`), so setup runs as a real first launch. Needs
/// `TEST_KAVITA_*` (with `TEST_KAVITA_LIBRARIES`, see `TestAccounts.libraries`) and `KAVITA_URL`
/// in `.env`; skipped without them.
final class SetupUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func fresh() -> XCUIApplication {
        XCUIApplication.setup(data: "yomu-\(UUID().uuidString.prefix(8))")
    }

    func testSkippingAtWelcomeStaysSkipped() throws {
        let app = fresh()
        app.launch()
        XCTAssertTrue(app.buttons["setup.getStarted"].waitForExistence(timeout: 20), "setup shows on a first launch")
        app.buttons["setup.later"].tap()
        XCTAssertTrue(app.alerts["Set up later?"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.alerts.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Run Setup Again'")).firstMatch.exists)
        app.alerts.buttons["Skip"].tap()
        XCTAssertTrue(app.staticTexts["Connect Kavita"].waitForExistence(timeout: 10), "the library says what's missing")
        app.terminate()
        app.launch()
        XCTAssertFalse(app.buttons["setup.getStarted"].waitForExistence(timeout: 5), "skipped stays skipped")
    }

    func testWrongAddressOrKeyDoesntContinue() throws {
        let (url, key) = try { let v = try TestAccounts.require("KAVITA_URL", "TEST_KAVITA_KEY"); return (v[0], v[1]) }()
        let app = fresh()
        app.launch()
        app.buttons["setup.getStarted"].tap()
        XCTAssertTrue(app.waitForTitle("Connect Kavita"))
        app.type("https://kavita.invalid", into: "setup.server.url")
        app.type("not-a-key", into: "setup.server.key")
        app.buttons["setup.continue"].tap()
        let status = app.element("setup.server.status")
        XCTAssertTrue(status.waitForExistence(timeout: 30))
        XCTAssertEqual(app.buttons["setup.continue"].label, "Connect", "a wrong address doesn't connect")

        let field = app.element("setup.server.url")
        field.tap()
        field.press(forDuration: 1.2)
        if app.menuItems["Select All"].waitForExistence(timeout: 3) { app.menuItems["Select All"].tap() }
        field.typeText(XCUIKeyboardKey.delete.rawValue)
        field.typeText(url)
        app.buttons["setup.continue"].tap()
        let failed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != ''"), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [failed], timeout: 30), .completed)
        XCTAssertEqual(app.buttons["setup.continue"].label, "Connect", "a wrong key doesn't connect")
        _ = key
    }

    /// Server, libraries (the guess), dictionaries (the recommended set, live), stopping at
    /// Anki and resuming there, no Anki, each extra, Done; then an update from Check Now.
    func testWholeSetupResumesAndUpdates() throws {
        let (url, key) = try { let v = try TestAccounts.require("KAVITA_URL", "TEST_KAVITA_KEY"); return (v[0], v[1]) }()
        let libraries = try TestAccounts.libraries("TEST_KAVITA_LIBRARIES")
        let app = fresh()
        app.launch()
        app.buttons["setup.getStarted"].tap()

        XCTAssertTrue(app.waitForTitle("Connect Kavita"))
        app.type(url, into: "setup.server.url")
        app.type(key, into: "setup.server.key")
        app.buttons["setup.continue"].tap()
        let connected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS 'libraries found'"),
                                                  object: app.element("setup.server.status"))
        XCTAssertEqual(XCTWaiter.wait(for: [connected], timeout: 30), .completed, "tested inline")
        app.tapContinue()

        XCTAssertTrue(app.waitForTitle("Which libraries are Japanese?"))
        let manga = app.switches["setup.library.\(libraries.japanese)"], books = app.switches["setup.library.\(libraries.english)"]
        XCTAssertTrue(manga.waitForExistence(timeout: 30))
        XCTAssertEqual(manga.value as? String, "1", "a Japanese name starts on")
        XCTAssertEqual(books.value as? String, "0", "an English one starts off")
        app.tapContinue()

        XCTAssertTrue(app.waitForTitle("Get dictionaries"), "no other app's setup to reuse; saw \(app.staticTexts["setup.title"].label)")
        XCTAssertEqual(app.element("recommended.jitendex").value as? String != nil, true)
        // The whole set, live: several minutes on a simulator.
        app.tapContinue(timeout: 900)

        XCTAssertTrue(app.waitForTitle("Connect Anki"))
        // Leave mid-way: setup comes back at the same step.
        app.terminate()
        app.launch()
        XCTAssertTrue(app.waitForTitle("Connect Anki"), "resumes where it was left")
        app.buttons["setup.anki.skip"].tap()

        XCTAssertTrue(app.waitForTitle("Extras"))
        for extra in ["Manga Text Recognition", "Read-Along", "kechimochi"] {
            app.element("setup.extra.\(extra)").tap()
            XCTAssertTrue(app.navigationBars.buttons.firstMatch.waitForExistence(timeout: 10), "\(extra) opens")
            app.navigationBars.buttons.firstMatch.tap()
            XCTAssertTrue(app.waitForTitle("Extras"), "and comes back")
        }
        app.tapContinue()

        XCTAssertTrue(app.staticTexts["setup.done"].waitForExistence(timeout: 10))
        let anki = app.element("setup.checklist.Anki")
        XCTAssertTrue(anki.label.contains("Later"), "Done says where the skipped step waits")
        XCTAssertTrue(app.element("setup.checklist.Dictionaries").label.contains("5 installed"))
        app.buttons["setup.start"].tap()
        XCTAssertFalse(app.buttons["setup.start"].waitForExistence(timeout: 3))

        // An update: Jitendex looks out of date; Check Now replaces it.
        app.terminate()
        app.launchEnvironment["UITEST_STALE_DICTIONARY"] = "jitendex"
        app.launch()
        app.tabBars.buttons["Settings"].tap()
        app.element("settings.dictionaries").tap()
        let checkNow = app.buttons["dictionaries.checkNow"]
        XCTAssertTrue(checkNow.waitForExistence(timeout: 10))
        checkNow.tap()
        let updated = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS 'Updated Jitendex'"), object: checkNow)
        XCTAssertEqual(XCTWaiter.wait(for: [updated], timeout: 600), .completed, "Check Now replaced it")

        // Run Setup Again: opens right away with Kavita connected; this time with Anki.
        guard let anki = TestAccounts.values["ANKI_URL"] else { return }
        app.navigationBars.buttons.firstMatch.tap()
        let advanced = app.element("settings.advanced")
        for _ in 0..<5 where !advanced.isHittable { app.swipeUp() }
        advanced.tap()
        app.buttons["advanced.runSetup"].tap()
        XCTAssertTrue(app.buttons["setup.getStarted"].waitForExistence(timeout: 10), "opens right away")
        app.buttons["setup.getStarted"].tap()
        XCTAssertTrue(app.waitForTitle("Connect Kavita"))
        XCTAssertEqual(app.buttons["setup.continue"].label, "Continue", "the server shows as connected")
        app.tapContinue()
        XCTAssertTrue(app.waitForTitle("Which libraries are Japanese?"))
        app.tapContinue()
        XCTAssertTrue(app.waitForTitle("Get dictionaries"))
        app.tapContinue()
        XCTAssertTrue(app.waitForTitle("Connect Anki"))
        app.type(anki, into: "setup.anki.url")
        if let key = TestAccounts.values["ANKI_KEY"], !key.isEmpty { app.type(key, into: "setup.anki.key") }
        app.buttons["setup.anki.test"].tap()
        app.tapContinue()
        XCTAssertTrue(app.waitForTitle("Where should cards go?"))
        XCTAssertTrue(app.element("setup.cards.review").waitForExistence(timeout: 20))
        app.tapContinue()
        XCTAssertTrue(app.waitForTitle("Extras"))
        app.tapContinue()
        XCTAssertTrue(app.staticTexts["setup.done"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.element("setup.checklist.Anki").label.contains("Later"))
        app.buttons["setup.start"].tap()
    }
}
