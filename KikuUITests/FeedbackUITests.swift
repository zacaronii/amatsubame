import XCTest

/// Settings ▸ About offers Report a Bug and Suggest an Idea (GitHub issues, filled in).
final class FeedbackUITests: XCTestCase {
    func testAboutOffersFeedback() {
        let app = XCUIApplication()
        app.launchEnvironment["UITEST_KIKU"] = "1"
        app.launch()
        app.tabBars.buttons["Settings"].tap()
        app.revealSettingsRow("settings.about").tap()
        let report = app.descendants(matching: .any)["about.reportBug"].firstMatch
        XCTAssertTrue(report.waitForExistence(timeout: 10), "Report a Bug")
        XCTAssertTrue(app.descendants(matching: .any)["about.suggestIdea"].firstMatch.exists, "Suggest an Idea")
        keepScreenshot(app, "about-feedback")
    }
}
