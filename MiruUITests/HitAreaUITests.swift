import XCTest

/// A transcript line's time in Lines is at least 44 pt tall to tap (the UI sweep's "Hit area is
/// too small"), while the lines keep their spacing.
final class HitAreaUITests: XCTestCase {
    func testLineTimesAreBigEnoughToTap() {
        let app = XCUIApplication()
        app.launchEnvironment["UITEST_MUTE"] = "1"
        app.launchEnvironment["UITEST_PLAYER"] = "1"
        app.launchEnvironment["UITEST_TRANSCRIPT"] = "1"
        app.launch()
        app.tabBars.buttons["Lines"].tap()
        let episode = app.buttons["lines.episode"].firstMatch
        XCTAssertTrue(episode.waitForExistence(timeout: 5))
        episode.tap()
        let times = app.buttons.matching(identifier: "transcript.playLine")
        XCTAssertTrue(times.firstMatch.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(times.firstMatch.frame.height, 44, "\(times.firstMatch.frame)")
        // The lines themselves didn't move apart: consecutive lines' times are closer than two tap heights.
        let first = times.element(boundBy: 0).frame, second = times.element(boundBy: 1).frame
        XCTAssertLessThan(second.midY - first.midY, 88, "lines \(first) and \(second)")
    }
}
