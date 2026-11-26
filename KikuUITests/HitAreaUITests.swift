import XCTest

/// The player's small controls are at least 44 pt to tap (the UI sweep's "Hit area is too small"),
/// while they look the same.
final class HitAreaUITests: XCTestCase {
    func testPlayerControlsAreBigEnoughToTap() {
        let app = XCUIApplication()
        app.launchEnvironment = ["UITEST_KIKU": "1", "UITEST_KIKU_PLAYER": "1", "UITEST_MUTE": "1"]
        app.launch()
        XCTAssertTrue(app.buttons["player.playPause"].waitForExistence(timeout: 15))
        for id in ["player.close", "player.mark"] {
            let frame = app.buttons[id].firstMatch.frame
            XCTAssertGreaterThanOrEqual(frame.width, 44, "\(id) \(frame)")
            XCTAssertGreaterThanOrEqual(frame.height, 44, "\(id) \(frame)")
        }
        // (A line's time stays as it is: taller, it would cover the top of its line, where a hold
        // opens Copy Line.)
    }
}
