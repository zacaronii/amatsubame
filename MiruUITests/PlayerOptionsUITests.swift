import XCTest

/// Pause After Each Line, which the player's options menu and the O key switch on. (The menu's
/// own items can't be seen by a UI test; they were checked by eye.) Needs a local test video
/// (UITEST_PLAYER_VIDEO); the lines come from the canned Jimaku file.
final class PlayerOptionsUITests: XCTestCase {
    func testPauseAfterEachLine() throws {
        guard let video = ProcessInfo.processInfo.environment["UITEST_PLAYER_VIDEO"] else {
            throw XCTSkip("Set TEST_RUNNER_UITEST_PLAYER_VIDEO to a video file.")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment = ["UITEST_PLAYER": "1", "UITEST_PLAYER_VIDEO": video, "UITEST_JIMAKU": "1"]
        app.launch()
        let player = app.descendants(matching: .any)["player.video"].firstMatch
        XCTAssertTrue(player.waitForExistence(timeout: 10))
        let osd = app.staticTexts["player.osd"]
        // Japanese lines from the canned Jimaku answer.
        let find = app.buttons["player.noSubtitles"]
        for _ in 0..<3 where !(find.waitForExistence(timeout: 3) && find.isHittable) { player.tap() }
        find.tap()
        let file = app.buttons.matching(identifier: "subtitles.file").firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: 10))
        file.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "subtitle.line").firstMatch.waitForExistence(timeout: 10))

        // Pause After Each Line (O does what the menu's switch does): playing stops by itself
        // at the end of a line, with the line still showing.
        player.typeKey("o", modifierFlags: [])
        XCTAssertTrue(osd.waitForExistence(timeout: 3))
        XCTAssertTrue(osd.label.hasPrefix("Pausing after each line"), osd.label)
        let playPause = app.buttons["player.playPause"].firstMatch
        let paused = NSPredicate { _, _ in playPause.exists && playPause.label == "Play" }
        XCTAssertEqual(XCTWaiter().wait(for: [expectation(for: paused, evaluatedWith: nil)], timeout: 30), .completed, "paused at the end of a line")
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "subtitle.line").firstMatch.exists, "the line is still there to read")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "paused after a line"
        shot.lifetime = .keepAlways
        add(shot)

        // Off again for the next run (it's remembered).
        player.typeKey("o", modifierFlags: [])
        XCTAssertTrue(osd.waitForExistence(timeout: 3))
    }
}
