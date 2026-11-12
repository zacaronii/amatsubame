import XCTest

/// mpv's keyboard shortcuts in the player (an iPad keyboard here; the Mac shares the
/// same list). Needs a local test video (UITEST_PLAYER_VIDEO).
final class PlayerShortcutsUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        guard let video = ProcessInfo.processInfo.environment["UITEST_PLAYER_VIDEO"] else {
            throw XCTSkip("Set TEST_RUNNER_UITEST_PLAYER_VIDEO to a video file to test the shortcuts.")
        }
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["UITEST_PLAYER"] = "1"
        app.launchEnvironment["UITEST_PLAYER_VIDEO"] = video
        app.launchEnvironment["UITEST_JIMAKU"] = "1"
    }

    private var player: XCUIElement { app.descendants(matching: .any)["player.video"].firstMatch }
    private var osd: XCUIElement { app.staticTexts["player.osd"] }

    private func press(_ key: String, _ modifiers: XCUIElement.KeyModifierFlags = []) {
        player.typeKey(key, modifierFlags: modifiers)
    }

    private func expectOSD(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        var seen: [String] = []
        let shown = NSPredicate { _, _ in
            let label = self.osd.exists ? self.osd.label : ""
            if !label.isEmpty, seen.last != label { seen.append(label) }
            return label.hasPrefix(text)
        }
        let result = XCTWaiter().wait(for: [expectation(for: shown, evaluatedWith: nil)], timeout: 3)
        XCTAssertEqual(result, .completed, "expected \"\(text)\", saw \(seen), keys \(app.staticTexts["player.debugKeys"].label)", file: file, line: line)
    }

    func testMpvShortcuts() {
        app.launch()
        XCTAssertTrue(player.waitForExistence(timeout: 10))
        // Japanese lines from the canned Jimaku answer, for the subtitle keys.
        let find = app.buttons["player.noSubtitles"]
        // It's in the controls, which hide a few seconds after the video starts.
        for _ in 0..<3 where !(find.waitForExistence(timeout: 3) && find.isHittable) { player.tap() }
        find.tap()
        let file = app.buttons.matching(identifier: "subtitles.file").firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: 10))
        file.tap()
        let line = app.descendants(matching: .any).matching(identifier: "subtitle.line").firstMatch
        XCTAssertTrue(line.waitForExistence(timeout: 10))
        sleep(1)

        press("]")
        expectOSD("Speed 1.10×")
        // (Shifted keys like { are left to the unit tests: the simulator's typeKey drops Shift
        // now and then.)
        press("[")
        expectOSD("Speed 1.00×")
        press("]")
        expectOSD("Speed 1.10×")
        // (Backspace for normal speed: the simulator never sends it to the app; checked on the Mac.)
        press("[")
        expectOSD("Speed 1.00×")

        press("l")
        expectOSD("Loop start")
        sleep(1)
        press("l")
        expectOSD("Looping")
        press("l")
        expectOSD("Loop off")

        press("m")
        expectOSD("Muted")
        press("m")
        expectOSD("Sound on")
        press("0")
        expectOSD("Volume")

        press("x")
        expectOSD("Subtitle timing +0.1 s")
        press("z")
        expectOSD("Subtitle timing +0.0 s")
        press("v")
        expectOSD("Japanese subtitles hidden")
        XCTAssertTrue(line.waitForNonExistence(timeout: 3), "the lines hide")
        press("v")
        expectOSD("Japanese subtitles shown")
        XCTAssertTrue(line.waitForExistence(timeout: 3))
        press("j")
        expectOSD("Only one Japanese subtitle track")
        press("#")
        expectOSD("Only one audio track")

        press("i")
        XCTAssertTrue(app.descendants(matching: .any)["player.streamInfo"].waitForExistence(timeout: 3), "stream info shows")
        press("i")

        // ? is Shift-/; a dropped Shift types /, which does nothing, so try again.
        let sheet = app.buttons["shortcuts.done"]
        for _ in 0..<3 where !sheet.exists {
            press("/", .shift)
            _ = sheet.waitForExistence(timeout: 2)
        }
        XCTAssertTrue(sheet.exists, "the cheat sheet opens; keys \(app.staticTexts["player.debugKeys"].label)")
        XCTAssertTrue(app.descendants(matching: .any)["shortcut.playPause"].exists, "it lists the shortcuts")
        // (Esc and Backspace never reach the app from the simulator's typeKey; they're checked
        // on the Mac with real key presses.)
        sheet.tap()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 3))

        press("a")
        let popup = app.descendants(matching: .any)["player.lookup"]
        XCTAssertTrue(popup.waitForExistence(timeout: 5), "A looks up the line")
        player.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.2)).tap()
        XCTAssertTrue(popup.waitForNonExistence(timeout: 3))

        press("q")
        XCTAssertTrue(player.waitForNonExistence(timeout: 5), "Q closes the video")
    }

    func testCheatSheetInSettings() {
        app.launchEnvironment["UITEST_PLAYER_VIDEO"] = nil
        app.launch()
        app.tabBars.buttons["Settings"].firstMatch.tap()
        let row = app.descendants(matching: .any)["settings.shortcuts"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any)["shortcut.fullScreen"].exists == false, "no full screen on iPhone and iPad")
        XCTAssertTrue(app.descendants(matching: .any)["shortcut.playPause"].waitForExistence(timeout: 5))
    }
}
