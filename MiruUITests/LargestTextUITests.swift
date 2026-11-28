import XCTest

/// At the largest accessibility text size a Lines row puts its picture above the text, which then
/// wraps instead of being cut off (the UI sweep's "Text clipped").
final class LargestTextUITests: XCTestCase {
    func testLinesRowStacks() {
        let app = XCUIApplication()
        app.launchEnvironment["UITEST_MUTE"] = "1"
        app.launchEnvironment["UITEST_PLAYER"] = "1"
        app.launchEnvironment["UITEST_TRANSCRIPT"] = "1"
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        app.tabBars.buttons["Lines"].tap()
        let row = app.buttons["lines.episode"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        let show = row.staticTexts["UI Test Show"].firstMatch
        XCTAssertTrue(show.exists)
        // Stacked: the title starts at the row's left edge, below the picture, not beside it.
        keepScreenshot(app, "largest-lines")
        XCTAssertLessThan(show.frame.minX - row.frame.minX, 40, "the title isn't beside the picture: \(show.frame) in \(row.frame)")
    }
}
