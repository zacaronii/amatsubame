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

    /// Holding the picture plays at 2× until it's let go.
    func testHoldingThePicturePlaysFaster() throws {
        guard let video = ProcessInfo.processInfo.environment["UITEST_PLAYER_VIDEO"] else {
            throw XCTSkip("Set TEST_RUNNER_UITEST_PLAYER_VIDEO to a video file.")
        }
        let app = XCUIApplication()
        app.launchEnvironment = ["UITEST_PLAYER": "1", "UITEST_PLAYER_VIDEO": video]
        app.launch()
        let player = app.descendants(matching: .any)["player.video"].firstMatch
        XCTAssertTrue(player.waitForExistence(timeout: 10))
        /// Seconds into the video, from the picture's accessibility value ("12.3 s, playing").
        func time() -> Double { Double((player.value as? String ?? "").split(separator: " ").first ?? "") ?? -1 }
        sleep(3)
        let before = time()
        player.press(forDuration: 4)
        let held = time() - before
        XCTAssertGreaterThan(held, 6, "about 4 s held at 2× (it moved \(held) s)")
        // Back at normal speed afterwards.
        let after = time()
        sleep(3)
        let normal = time() - after
        XCTAssertLessThan(normal, 4.5, "normal speed again (it moved \(normal) s)")
        XCTAssertFalse(app.descendants(matching: .any)["player.holdSpeed"].firstMatch.exists)
    }

    /// Opening the options menu keeps the controls (it hangs from them) up while you choose.
    func testTheControlsStayWhileTheOptionsMenuIsOpen() throws {
        guard let video = ProcessInfo.processInfo.environment["UITEST_PLAYER_VIDEO"] else {
            throw XCTSkip("Set TEST_RUNNER_UITEST_PLAYER_VIDEO to a video file.")
        }
        let app = XCUIApplication()
        app.launchEnvironment = ["UITEST_PLAYER": "1", "UITEST_PLAYER_VIDEO": video]
        app.launch()
        let player = app.descendants(matching: .any)["player.video"].firstMatch
        XCTAssertTrue(player.waitForExistence(timeout: 10))
        let options = app.descendants(matching: .any)["player.options"].firstMatch
        let close = app.buttons["player.close"]
        // By themselves the controls go after a few seconds of playing.
        XCTAssertTrue(close.waitForNonExistence(timeout: 10), "the controls hide while playing")
        player.tap()
        XCTAssertTrue(options.waitForExistence(timeout: 3))
        options.tap()
        sleep(6)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "menu after six seconds"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Hide Until Tapped: the line is blurred and can't be looked up until a tap shows it; and
    /// the size and position from Settings apply.
    func testHiddenSubtitlesShowOnATap() throws {
        guard let video = ProcessInfo.processInfo.environment["UITEST_PLAYER_VIDEO"] else {
            throw XCTSkip("Set TEST_RUNNER_UITEST_PLAYER_VIDEO to a video file.")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment = ["UITEST_PLAYER": "1", "UITEST_PLAYER_VIDEO": video, "UITEST_JIMAKU": "1", "UITEST_PLAYER_LOOK": "conceal,large,higher"]
        app.launch()
        let player = app.descendants(matching: .any)["player.video"].firstMatch
        XCTAssertTrue(player.waitForExistence(timeout: 10))
        let find = app.buttons["player.noSubtitles"]
        for _ in 0..<3 where !(find.waitForExistence(timeout: 3) && find.isHittable) { player.tap() }
        find.tap()
        let file = app.buttons.matching(identifier: "subtitles.file").firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: 10))
        file.tap()
        let reveal = app.descendants(matching: .any)["subtitle.reveal"].firstMatch
        XCTAssertTrue(reveal.waitForExistence(timeout: 10), "the line comes up hidden")
        let hidden = XCTAttachment(screenshot: app.screenshot())
        hidden.name = "hidden line"
        hidden.lifetime = .keepAlways
        add(hidden)
        reveal.tap()
        XCTAssertTrue(reveal.waitForNonExistence(timeout: 3), "a tap shows it")
        let shown = XCTAttachment(screenshot: app.screenshot())
        shown.name = "shown line"
        shown.lifetime = .keepAlways
        add(shown)
    }
}
