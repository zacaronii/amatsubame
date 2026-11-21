import XCTest

/// Settings ▸ Transcripts against a real Kaku (in memory, read only): once it's set up, the
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
        let row = app.descendants(matching: .any)["settings.transcripts"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()

        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(url)
        let tokenField = app.secureTextFields.firstMatch
        tokenField.tap()
        tokenField.typeText(token)
        app.buttons["Test Connection"].firstMatch.tap()

        // The sections come in from the server without anything else to tap.
        XCTAssertTrue(app.staticTexts["Now Transcribing"].waitForExistence(timeout: 20), "the server's sections load")
        shot(app, "kaku server")
        for _ in 0..<4 where !app.staticTexts["Libraries"].exists { app.swipeUp() }
        XCTAssertTrue(app.staticTexts["Libraries"].waitForExistence(timeout: 5), "each library is listed")
        shot(app, "kaku libraries")
    }
}
