import XCTest

extension XCTestCase {
    /// The options menu's English Subtitles: the English line on, off and on again (debug
    /// builds put the engine's English track and line in the picture's accessibility value). Checked paused: while
    /// the video plays, that value changes ten times a second, XCTest waits for the app to go
    /// idle before each tap (about 55 s), and the video ends before a line can show (#314). mpv
    /// draws the line at the paused frame, so it needs a line there.
    func checkEnglishTurnsOnAndOff(_ app: XCUIApplication, player: XCUIElement) {
        let options = app.descendants(matching: .any)["player.options"].firstMatch
        // On: mpv has a track and draws a line (within a few lines' time); off: no track.
        func shows(_ english: Bool) -> Bool {
            let predicate = NSPredicate { _, _ in
                let value = player.value as? String ?? ""
                return english ? !value.contains("sid: no") && value.contains(" line: ")
                    : value.contains("sid: no") && !value.contains(" line: ")
            }
            return XCTWaiter().wait(for: [expectation(for: predicate, evaluatedWith: nil)], timeout: english ? 30 : 8) == .completed
        }
        func toggle(_ step: String) {
            for _ in 0..<3 where !(options.waitForExistence(timeout: 2) && options.isHittable) { player.tap() }
            options.tap()
            let item = app.switches["English Subtitles"].firstMatch.exists ? app.switches["English Subtitles"].firstMatch
                : app.buttons["English Subtitles"].firstMatch
            XCTAssertTrue(item.waitForExistence(timeout: 5), "\(step): English Subtitles in the menu")
            item.tap()
        }
        XCTAssertTrue(shows(false), "off to begin with")
        player.twoFingerTap()
        let paused = NSPredicate { _, _ in (player.value as? String ?? "").contains("paused") }
        XCTAssertEqual(XCTWaiter().wait(for: [expectation(for: paused, evaluatedWith: nil)], timeout: 5), .completed,
                       "a two-finger tap pauses: \(player.value ?? "")")
        toggle("on")
        XCTAssertTrue(shows(true), "on: \(player.value ?? "")")
        toggle("off")
        XCTAssertTrue(shows(false), "off again: \(player.value ?? "")")
        toggle("on again")
        XCTAssertTrue(shows(true), "on again: \(player.value ?? "")")
    }

    /// English turned off again before mpv has its file (Jellyfin can take a while to make one
    /// from a big file): it stays off when the file comes.
    func checkEnglishOffBeforeItLoads(_ app: XCUIApplication, player: XCUIElement) {
        let options = app.descendants(matching: .any)["player.options"].firstMatch
        /// Opens the menu and taps English Subtitles; how long the tap took (until the app was
        /// idle again).
        @discardableResult
        func toggle() -> TimeInterval {
            for _ in 0..<3 where !(options.waitForExistence(timeout: 2) && options.isHittable) { player.tap() }
            options.tap()
            let item = app.switches["English Subtitles"].firstMatch.exists ? app.switches["English Subtitles"].firstMatch
                : app.buttons["English Subtitles"].firstMatch
            XCTAssertTrue(item.waitForExistence(timeout: 5))
            let started = Date()
            item.tap()
            return Date().timeIntervalSince(started)
        }
        // The app answers at once while the file is coming (it used to wait for it, which on a
        // big file left English Subtitles unresponsive).
        XCTAssertLessThan(toggle(), 5, "turning English on doesn't wait for the file")
        toggle()
        sleep(25)
        let value = player.value as? String ?? ""
        XCTAssertTrue(value.contains("sid: no") && !value.contains(" line: "), "still off once the file came: \(value)")
        // And on again works.
        toggle()
        let on = NSPredicate { _, _ in (player.value as? String ?? "").contains(" line: ") }
        XCTAssertEqual(XCTWaiter().wait(for: [expectation(for: on, evaluatedWith: nil)], timeout: 20), .completed, "on again")
    }
}
