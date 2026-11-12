import XCTest

/// Miru's first-launch setup against a test account, reusing a setup Yomu made
/// first, or setting up separately. Needs `JELLYFIN_URL` and
/// `TEST_JELLYFIN_*` in `.env` (with `TEST_JELLYFIN_LIBRARIES`, see `TestAccounts.libraries`:
/// a Japanese-audio library and an English-audio one), and Yomu installed.
final class SetupUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func signIn(_ app: XCUIApplication) throws {
        let values = try TestAccounts.require("JELLYFIN_URL", "TEST_JELLYFIN_USER", "TEST_JELLYFIN_PASSWORD")
        let libraries = try TestAccounts.libraries("TEST_JELLYFIN_LIBRARIES")
        app.buttons["setup.getStarted"].tap()
        XCTAssertTrue(app.waitForTitle("Connect Jellyfin"))
        app.type(values[0], into: "setup.server.url")
        app.type(values[1], into: "setup.server.username")
        app.type(values[2], into: "setup.server.password")
        app.buttons["setup.continue"].tap()
        let connected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS 'libraries found'"),
                                                  object: app.element("setup.server.status"))
        XCTAssertEqual(XCTWaiter.wait(for: [connected], timeout: 30), .completed)
        app.tapContinue()

        XCTAssertTrue(app.waitForTitle("Which libraries are Japanese?"))
        let anime = app.switches["setup.library.\(libraries.japanese)"], shows = app.switches["setup.library.\(libraries.english)"]
        XCTAssertTrue(anime.waitForExistence(timeout: 60))
        XCTAssertEqual(anime.value as? String, "1", "Japanese audio: on")
        XCTAssertEqual(shows.value as? String, "0", "English audio: off")
        app.tapContinue()
    }

    func testReusingTheSetupYomuMade() throws {
        let data = "miru-reuse-\(UUID().uuidString.prefix(8))"
        try SharedSetupFixture.prepare(data: data)
        let app = XCUIApplication.setup(data: data)
        app.launch()
        try signIn(app)

        XCTAssertTrue(app.waitForTitle("Use your existing setup?"), "another app's setup is offered")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'already have dictionaries'")).firstMatch.exists,
                      "worded without knowing which app made it")
        app.buttons["setup.continue"].tap()

        XCTAssertTrue(app.waitForTitle("Extras"), "dictionaries and Anki are skipped")
        for extra in ["Jimaku", "Kaku", "kechimochi"] {
            app.element("setup.extra.\(extra)").tap()
            XCTAssertTrue(app.navigationBars.buttons.firstMatch.waitForExistence(timeout: 10), "\(extra) opens")
            app.navigationBars.buttons.firstMatch.tap()
            XCTAssertTrue(app.waitForTitle("Extras"))
        }
        app.tapContinue()
        XCTAssertTrue(app.staticTexts["setup.done"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.element("setup.checklist.Dictionaries").label.contains("1 installed"), "the shared dictionary")
        app.buttons["setup.start"].tap()
        XCTAssertFalse(app.buttons["setup.start"].waitForExistence(timeout: 3))
    }

    func testSettingUpSeparately() throws {
        let data = "miru-own-\(UUID().uuidString.prefix(8))"
        try SharedSetupFixture.prepare(data: data)
        let app = XCUIApplication.setup(data: data)
        app.launch()
        try signIn(app)

        XCTAssertTrue(app.waitForTitle("Use your existing setup?"))
        app.buttons["setup.separately"].tap()
        XCTAssertTrue(app.waitForTitle("Open Miru again"), "its own setup starts with the next launch")
        app.terminate()
        app.launch()
        XCTAssertTrue(app.waitForTitle("Get dictionaries"), "back at Dictionaries, with its own (empty) setup")
        XCTAssertNotEqual(app.element("recommended.kanjium").value as? String, "installed", "the shared dictionary isn't its own")
    }
}
