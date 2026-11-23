import XCTest

/// #166 in Kiku (in memory).
final class SettingsRetapUITests: XCTestCase {
    @MainActor
    func testSettingsTabReturnsToTheTopFromTwoScreensDeep() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment = ["UITEST_KIKU": "1"]
        app.launch()
        checkSettingsTabRetap(app)
    }

    /// The issue's own path: Settings ▸ Kaku (signed in, read only) ▸ Connection.
    @MainActor
    func testSettingsTabReturnsToTheTopFromKakuConnection() throws {
        let env = ProcessInfo.processInfo.environment
        guard let url = env["UITEST_KAKU_URL"], let token = env["UITEST_KAKU_TOKEN"] else {
            throw XCTSkip("Set TEST_RUNNER_UITEST_KAKU_URL and TEST_RUNNER_UITEST_KAKU_TOKEN.")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment = ["UITEST_KIKU": "1"]
        app.launch()
        let tab = app.tabBars.buttons["Settings"]
        tab.tap()
        let row = app.descendants(matching: .any)["settings.kaku"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        let field = app.textFields["kaku.url"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(url)
        let tokenField = app.secureTextFields["kaku.token"].firstMatch
        tokenField.tap()
        tokenField.typeText(token)
        app.buttons["kaku.test"].firstMatch.tap()
        let connection = app.descendants(matching: .any)["kaku.connection"].firstMatch
        XCTAssertTrue(app.staticTexts["Now Transcribing"].waitForExistence(timeout: 20), "connected")
        for _ in 0..<6 where !(connection.exists && connection.isHittable) { app.swipeUp() }
        connection.tap()
        XCTAssertTrue(app.textFields["kaku.url"].waitForExistence(timeout: 5), "Connection, two screens deep")
        // iOS offers to save the token as a password: a system sheet over the app that takes the
        // taps until it has gone. That's what swallowed the re-tap in #166's run, not the app.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for source in [app, springboard] where source.buttons["Not Now"].waitForExistence(timeout: 3) {
            let notNow = source.buttons["Not Now"]
            notNow.tap()
            XCTAssertTrue(notNow.waitForNonExistence(timeout: 5))
            sleep(1)   // its closing animation still takes a tap
            break
        }
        tab.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5), "the top of Settings")
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(app.staticTexts["Now Transcribing"].waitForExistence(timeout: 10), "the next tap opens Kaku")
    }
}

/// Listen's stack is driven by a path of its own (`ListenView.reset`): two screens deep (Library
/// ▸ a show), tapping Listen again shows its top, and the next tap opens Library. Needs Kiku
/// signed in to Audiobookshelf on the simulator (`DevSetup`); skipped otherwise.
final class ListenRetapUITests: XCTestCase {
    @MainActor
    func testListenTabReturnsToTheTopFromTwoScreensDeep() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        let library = app.buttons["listen.library"].firstMatch
        guard library.waitForExistence(timeout: 20) else { throw XCTSkip("Sign Kiku in to Audiobookshelf on the simulator (DevSetup).") }
        library.tap()
        let show = app.buttons["library.show"].firstMatch
        XCTAssertTrue(show.waitForExistence(timeout: 20), "the library's shows")
        show.tap()
        XCTAssertTrue(show.waitForNonExistence(timeout: 10), "a show, two screens deep")
        sleep(1)
        app.tabBars.buttons["Listen"].tap()
        XCTAssertTrue(library.waitForExistence(timeout: 5) && library.isHittable, "the top of Listen")
        library.tap()
        XCTAssertTrue(show.waitForExistence(timeout: 20), "the next tap opens Library")
    }
}
