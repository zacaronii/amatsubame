import XCTest

/// At the largest accessibility text size nothing that matters is cut off or out of reach (the
/// UI sweep's "Text clipped").
final class LargestTextUITests: XCTestCase {
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment = ["UITEST_KIKU": "1", "UITEST_STATS": "1"]
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        return app
    }

    func testListenEmptyStateScrollsToOpenSettings() {
        let app = launch()
        let open = app.buttons["listen.openSettings"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 15))
        for _ in 0..<6 where !open.isHittable { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(open.isHittable, "Open Settings can be reached")
        keepScreenshot(app, "largest-listen")
    }

    func testStatsTilesTakeTheFullWidth() {
        let app = launch()
        app.tabBars.buttons["Stats"].tap()
        let tile = app.descendants(matching: .any).matching(identifier: "stats.tile").firstMatch
        for _ in 0..<6 where !tile.exists { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(tile.waitForExistence(timeout: 10))
        let screen = app.windows.firstMatch.frame.width
        XCTAssertGreaterThan(tile.frame.width, screen * 0.8, "one tile per row: \(tile.frame) on \(screen)")
        keepScreenshot(app, "largest-stats")
    }
}
