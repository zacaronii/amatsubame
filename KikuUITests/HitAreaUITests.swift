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
        // Down to the mini player: its Play button too (the sweep flagged it on the iPhone Duo).
        app.buttons["player.close"].firstMatch.tap()
        let play = app.buttons["mini.playPause"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        XCTAssertGreaterThanOrEqual(play.frame.width, 44, "\(play.frame)")
        XCTAssertGreaterThanOrEqual(play.frame.height, 44, "\(play.frame)")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "mini player"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// A line's time is 44 pt to tap in its own space above the text, so holding the text still
    /// opens Copy Line (#300's first try let the time cover the text).
    func testLineTimeIsBigEnoughAndHoldingTheTextCopies() {
        let app = XCUIApplication()
        app.launchEnvironment = ["UITEST_KIKU": "1", "UITEST_KIKU_BOOK": "1", "UITEST_MUTE": "1"]
        app.launch()
        let row = app.descendants(matching: .any).matching(identifier: "player.line").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        let time = row.buttons["player.lineTime"]
        let text = row.descendants(matching: .any)["subtitle.line"].firstMatch
        XCTAssertGreaterThanOrEqual(time.frame.width, 44, "\(time.frame)")
        XCTAssertGreaterThanOrEqual(time.frame.height, 44, "\(time.frame)")
        XCTAssertLessThanOrEqual(time.frame.maxY, text.frame.minY + 0.5, "the time \(time.frame) stays above the text \(text.frame)")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "transcript lines"
        attachment.lifetime = .keepAlways
        add(attachment)

        text.press(forDuration: 1.0)
        let copy = app.buttons["Copy Line"].firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        copy.tap()
        XCTAssertTrue(copy.waitForNonExistence(timeout: 5))

        // Holding the time works too (the hold is the row's).
        time.press(forDuration: 1.0)
        XCTAssertTrue(app.buttons["Play from Here"].firstMatch.waitForExistence(timeout: 5))
    }
}
