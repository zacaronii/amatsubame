import XCTest

/// Settings ▸ Kaku against a real Kaku (in memory, read only): once it's set up, the
/// screen shows what the server is doing. Needs `TEST_RUNNER_UITEST_KAKU_URL` and
/// `TEST_RUNNER_UITEST_KAKU_TOKEN`.
final class KakuServerUITests: XCTestCase {
    func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testTheServerSectionsLoad() throws {
        let env = ProcessInfo.processInfo.environment
        guard let url = env["UITEST_KAKU_URL"], let token = env["UITEST_KAKU_TOKEN"] else {
            throw XCTSkip("Set TEST_RUNNER_UITEST_KAKU_URL and TEST_RUNNER_UITEST_KAKU_TOKEN.")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment = ["UITEST_KIKU": "1"]
        app.launch()
        app.tabBars.buttons["Settings"].tap()
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

        // The sections come in from the server without anything else to tap.
        XCTAssertTrue(app.staticTexts["Now Transcribing"].waitForExistence(timeout: 20), "the server's sections load")
        shot(app, "kaku server")
        for _ in 0..<4 where !app.staticTexts["Libraries"].exists { app.swipeUp() }
        XCTAssertTrue(app.staticTexts["Libraries"].waitForExistence(timeout: 5), "each library is listed")
        shot(app, "kaku libraries")

        // The address and token are on their own screen, at the end.
        let connection = app.descendants(matching: .any)["kaku.connection"].firstMatch
        for _ in 0..<4 where !(connection.exists && connection.isHittable) { app.swipeUp() }
        connection.tap()
        XCTAssertTrue(app.textFields["kaku.url"].waitForExistence(timeout: 5), "Connection has the address")
        shot(app, "kaku connection")
        // Back at the top of Settings, the row says what Kaku is doing.
        let summary = app.descendants(matching: .any)["settings.kaku"].firstMatch
        for _ in 0..<4 where !summary.exists {
            app.navigationBars.buttons["BackButton"].firstMatch.tap()
            _ = summary.waitForExistence(timeout: 2)
        }
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
        XCTAssertTrue(summary.label.contains("transcribed") || summary.label.contains("Transcribing"), summary.label)
        shot(app, "settings row")
    }
}
