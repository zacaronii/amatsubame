import XCTest

final class KikuUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func launch(_ extra: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment = ["UITEST_KIKU": "1"].merging(extra) { $1 }
        app.launch()
        return app
    }

    func testTabsAndSettings() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["Connect Audiobookshelf"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Marks"].tap()
        XCTAssertTrue(app.staticTexts["Marks you make while listening show up here."].waitForExistence(timeout: 5))
        app.tabBars.buttons["Settings"].tap()
        let row = app.descendants(matching: .any)["settings.audiobookshelf"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(app.buttons["audiobookshelf.signIn"].waitForExistence(timeout: 5))
        // Tapping the tab that's showing goes back to its top screen.
        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.buttons["audiobookshelf.signIn"].waitForNonExistence(timeout: 5), "back at the top of Settings")
        XCTAssertTrue(row.exists)
    }
}

/// Stats ▸ All immersion against a kechimochi server (read only): needs
/// `TEST_RUNNER_UITEST_KECHIMOCHI_URL`.
final class KikuImmersionUITests: XCTestCase {
    func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testAllImmersionShowsKechimochi() throws {
        guard let url = ProcessInfo.processInfo.environment["UITEST_KECHIMOCHI_URL"] else { throw XCTSkip("Set TEST_RUNNER_UITEST_KECHIMOCHI_URL.") }
        let app = XCUIApplication()
        app.launchEnvironment = ["UITEST_KIKU": "1"]
        app.launch()
        app.tabBars.buttons["Stats"].tap()
        app.buttons["All immersion"].tap()
        XCTAssertTrue(app.staticTexts["Connect kechimochi"].waitForExistence(timeout: 10), "asks for the address first")
        app.tabBars.buttons["Settings"].tap()
        let field = app.textFields["stats.kechimochiURL"]
        for _ in 0..<8 where !field.isHittable { app.swipeUp() }
        // Pasted, without Return, then straight back to Stats (All immersion still selected).
        UIPasteboard.general.string = url
        field.tap()
        field.press(forDuration: 1.2)
        let paste = app.menuItems["Paste"].firstMatch
        if paste.waitForExistence(timeout: 3) { paste.tap() } else { field.typeText(url) }
        shot(app, "pasted")
        // The keyboard covers the tab bar: put it away (without Return) first.
        app.swipeDown()
        if app.keyboards.firstMatch.exists { app.keyboards.buttons["Return"].firstMatch.tap() }
        app.tabBars.buttons["Stats"].tap()
        sleep(3)
        shot(app, "back-on-stats")
        let streak = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Longest streak'")).firstMatch
        XCTAssertTrue(streak.waitForExistence(timeout: 30), "kechimochi's totals")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Today:'")).firstMatch.exists, "the heatmap's caption")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "all-immersion"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

final class KikuPlayerUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// The player with a saved transcript and silent local audio: line jumps move the current
    /// line, scrolling turns follow off, and a lookup pauses until it's closed.
    func testPlayerLinesFollowAndLookup() throws {
        let app = XCUIApplication()
        app.launchEnvironment = ["UITEST_KIKU": "1", "UITEST_KIKU_PLAYER": "1"]
        app.launch()
        let playPause = app.buttons["player.playPause"]
        XCTAssertTrue(playPause.waitForExistence(timeout: 10))
        let current = app.descendants(matching: .any)["player.currentLine"]
        // Before the first line nothing is current; "next" jumps to it.
        app.buttons["player.nextLine"].tap()
        XCTAssertTrue(current.waitForExistence(timeout: 5))
        XCTAssertTrue(current.staticTexts.firstMatch.label.isEmpty || current.exists)
        app.buttons["player.nextLine"].tap()
        app.buttons["player.nextLine"].tap()
        XCTAssertTrue(current.descendants(matching: .any)["subtitle.line"].label.contains("読んだんですか"))
        app.buttons["player.previousLine"].tap()
        XCTAssertTrue(current.descendants(matching: .any)["subtitle.line"].label.contains("本屋"))

        // Play, then tap a word: paused while the lookup is open, playing again after.
        playPause.tap()
        XCTAssertEqual(playPause.value as? String, "playing")
        current.descendants(matching: .any)["subtitle.line"].tap()
        XCTAssertTrue(app.staticTexts["Playback paused · resumes when you close this"].waitForExistence(timeout: 5))
        XCTAssertEqual(playPause.value as? String, "paused")
        XCTAssertTrue(app.buttons["lookup.playClip"].exists)
        app.closeLookup()
        let resumed = expectation(for: NSPredicate(format: "value == 'playing'"), evaluatedWith: playPause)
        wait(for: [resumed], timeout: 5)

        // Scrolling by hand stops following; Back to Now resumes it.
        let backToNow = app.buttons["player.backToNow"]
        XCTAssertFalse(backToNow.exists)
        app.swipeUp()
        XCTAssertTrue(backToNow.waitForExistence(timeout: 5), "scrolled away: Back to Now")
        backToNow.tap()
        XCTAssertTrue(backToNow.waitForNonExistence(timeout: 5))

        // The speech bubble hides the transcript: the artwork with the line playing, small; a
        // tap on that line brings the transcript back. The choice is kept for the next player.
        let toggle = app.buttons["player.transcript"]
        XCTAssertEqual(toggle.value as? String, "On")
        toggle.tap()
        XCTAssertEqual(toggle.value as? String, "Off")
        let offLine = app.buttons["player.offLine"]
        XCTAssertTrue(offLine.waitForExistence(timeout: 5))
        XCTAssertTrue(offLine.label.contains("本屋") || offLine.label.contains("current line"), offLine.label)
        XCTAssertFalse(current.exists, "no transcript while it's off")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "transcript-off"
        attachment.lifetime = .keepAlways
        add(attachment)
        offLine.tap()
        XCTAssertEqual(toggle.value as? String, "On")
        XCTAssertTrue(current.waitForExistence(timeout: 5))
    }
}

/// Putting the player away without reaching for the arrow in the top corner.
final class KikuPlayerPullUITests: XCTestCase {
    func testPullingThePlayerDownClosesIt() {
        let app = XCUIApplication()
        app.launchEnvironment = ["UITEST_KIKU": "1", "UITEST_KIKU_PLAYER": "1"]
        app.launch()
        let close = app.buttons["player.close"]
        let mini = app.descendants(matching: .any)["mini.player"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 10))

        // A nudge on the top bar springs back.
        let top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.09))
        top.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.13)),
                  withVelocity: .slow, thenHoldForDuration: 0.3)
        XCTAssertTrue(close.waitForExistence(timeout: 2), "a nudge doesn't close it")

        // Pulled down from the top bar: closed, with the mini player in its place.
        top.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55)))
        XCTAssertTrue(mini.waitForExistence(timeout: 5), "pulled down from the top bar")
        XCTAssertTrue(close.waitForNonExistence(timeout: 5))

        // A swipe up on the mini player opens it again.
        mini.swipeUp()
        XCTAssertTrue(close.waitForExistence(timeout: 5), "a swipe up on the mini player opens it")

        // And from the controls, within the thumb's reach (between the scrubber and the buttons).
        let controls = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.855))
        controls.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.999)),
                       withVelocity: .fast, thenHoldForDuration: 0)
        XCTAssertTrue(close.waitForNonExistence(timeout: 5), "flicked down from the controls")

        // The scrubber still scrubs: a sideways drag on it leaves the player open.
        mini.tap()
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        let scrubber = app.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.805))
        scrubber.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.82)))
        XCTAssertTrue(close.waitForExistence(timeout: 2), "scrubbing doesn't close the player")
    }
}

/// The lookup's bottom panel: a slow pull on its handle shrinks it and lets go closed, never
/// up to the full height (it used to rubber-band and could end as a flick up).
final class KikuLookupPanelUITests: XCTestCase {
    func testPullingTheHandleDownSlowlyClosesThePanel() {
        let app = XCUIApplication()
        app.launchEnvironment = ["UITEST_KIKU": "1", "UITEST_KIKU_PLAYER": "1"]
        app.launch()
        XCTAssertTrue(app.buttons["player.playPause"].waitForExistence(timeout: 10))
        app.buttons["player.nextLine"].tap()
        let line = app.descendants(matching: .any)["player.currentLine"].descendants(matching: .any)["subtitle.line"].firstMatch
        XCTAssertTrue(line.waitForExistence(timeout: 5))
        let handle = app.descendants(matching: .any)["lookup.handle"].firstMatch

        for (name, velocity) in [("slow", XCUIGestureVelocity.slow), ("default", .default)] {
            line.tap()
            XCTAssertTrue(handle.waitForExistence(timeout: 5), "\(name): the panel opens")
            XCTAssertEqual(handle.value as? String, "Half")
            let start = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            start.press(forDuration: 0.15, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 160)), withVelocity: velocity, thenHoldForDuration: 0.2)
            XCTAssertTrue(handle.waitForNonExistence(timeout: 3), "\(name): pulled down, it closes (\(handle.exists ? handle.value as? String ?? "" : "closed"))")
        }

        // Up still makes it full, and down from there half.
        line.tap()
        XCTAssertTrue(handle.waitForExistence(timeout: 5))
        let start = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.15, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -160)), withVelocity: .slow, thenHoldForDuration: 0.2)
        XCTAssertEqual(handle.value as? String, "Full")
        let top = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        top.press(forDuration: 0.15, thenDragTo: top.withOffset(CGVector(dx: 0, dy: 160)), withVelocity: .slow, thenHoldForDuration: 0.2)
        XCTAssertEqual(handle.value as? String, "Half")
    }
}

final class KikuBookUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// A book in the player shows its chapter, and Chapters jumps to another.
    func testChaptersInThePlayer() {
        let app = XCUIApplication()
        app.launchEnvironment = ["UITEST_KIKU": "1", "UITEST_KIKU_BOOK": "1"]
        app.launch()
        let subtitle = app.staticTexts["player.subtitle"]
        XCTAssertTrue(subtitle.waitForExistence(timeout: 10))
        XCTAssertEqual(subtitle.label, "第一章 夢")
        app.buttons["More"].tap()
        app.buttons["Chapters"].tap()
        let third = app.buttons.matching(identifier: "chapters.chapter").element(boundBy: 1)
        XCTAssertTrue(third.waitForExistence(timeout: 5))
        third.tap()
        let jumped = expectation(for: NSPredicate(format: "label == '第三章 再会'"), evaluatedWith: subtitle)
        wait(for: [jumped], timeout: 5)
        app.buttons["More"].tap()
        app.buttons["Previous Chapter"].tap()
        let back = expectation(for: NSPredicate(format: "label == '第三章 再会' OR label == '第二章 出会い'"), evaluatedWith: subtitle)
        wait(for: [back], timeout: 5)
    }

    /// A book's sleep timer can stop at the end of the chapter, and a held line can be copied.
    func testEndOfChapterTimerAndCopyLine() {
        let app = XCUIApplication()
        app.launchEnvironment = ["UITEST_KIKU": "1", "UITEST_KIKU_BOOK": "1"]
        app.launch()
        XCTAssertTrue(app.staticTexts["player.subtitle"].waitForExistence(timeout: 10))
        app.buttons["More"].tap()
        app.buttons["Sleep Timer"].firstMatch.tap()
        let endOfChapter = app.buttons["End of Chapter"].firstMatch
        XCTAssertTrue(endOfChapter.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["End of Book"].exists, "a book's own wording")
        endOfChapter.tap()
        app.buttons["More"].tap()
        XCTAssertTrue(app.buttons["Sleep Timer · End of Chapter"].firstMatch.waitForExistence(timeout: 5), "the timer is set")
        app.buttons["Sleep Timer · End of Chapter"].firstMatch.tap()
        app.buttons["Turn Off"].firstMatch.tap()

        // Hold a line: Copy Line and Play from Here (the clipboard itself isn't read here: the
        // test runner asking for it hangs on the simulator).
        let line = app.descendants(matching: .any).matching(identifier: "player.line").firstMatch
        XCTAssertTrue(line.waitForExistence(timeout: 5))
        line.press(forDuration: 1.0)
        let copy = app.buttons["Copy Line"].firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Play from Here"].exists)
        copy.tap()
        XCTAssertTrue(copy.waitForNonExistence(timeout: 5))
    }

    /// More ▸ Transcript says what made the transcript and offers Transcribe Again (#149).
    func testTranscriptMenuSaysWhatMadeIt() {
        let app = XCUIApplication()
        app.launchEnvironment = ["UITEST_KIKU": "1", "UITEST_KIKU_BOOK": "1"]
        app.launch()
        XCTAssertTrue(app.staticTexts["player.subtitle"].waitForExistence(timeout: 10))
        app.buttons["More"].tap()
        let menu = app.buttons["player.transcriptMenu"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        menu.tap()
        let again = app.buttons["Transcribe Again"].firstMatch
        XCTAssertTrue(again.waitForExistence(timeout: 5))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "transcript menu"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

final class KikuMarksAndStatsUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// Searching played episodes' transcripts, and a result opening the player at its line.
    func testMarksSearchOpensThePlayerAtTheLine() {
        let app = XCUIApplication()
        app.launchEnvironment = ["UITEST_KIKU": "1", "UITEST_KIKU_PLAYER": "1"]
        app.launch()
        let close = app.buttons["player.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 10))
        close.tap()
        XCTAssertTrue(app.descendants(matching: .any)["mini.player"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Marks"].tap()
        XCTAssertTrue(app.staticTexts["Marks you make while listening show up here."].waitForExistence(timeout: 5))
        let field = app.searchFields.firstMatch
        field.tap()
        field.typeText("過ごし方")
        let result = app.buttons["marks.result"].firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["In episodes you've played · 1"].exists)
        result.tap()
        // The line the result named becomes current (the old current line shows first).
        let current = app.descendants(matching: .any)["player.currentLine"].descendants(matching: .any)["subtitle.line"]
        let jumped = expectation(for: NSPredicate(format: "label CONTAINS '過ごし方'"), evaluatedWith: current)
        wait(for: [jumped], timeout: 5)
    }

    /// A mark from the player lists its lines in Marks; a word opens the lookup, and Clear
    /// removes the mark.
    func testMarkFromThePlayerThenLookUpAndClear() {
        let app = XCUIApplication()
        app.launchEnvironment = ["UITEST_KIKU": "1", "UITEST_KIKU_PLAYER": "1"]
        app.launch()
        XCTAssertTrue(app.buttons["player.playPause"].waitForExistence(timeout: 10))
        for _ in 0..<4 { app.buttons["player.nextLine"].tap() }
        app.buttons["player.mark"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["player.markToast"].waitForExistence(timeout: 3))
        app.buttons["player.close"].tap()
        app.tabBars.buttons["Marks"].tap()

        let marked = app.descendants(matching: .any)["mark.markedLine"]
        XCTAssertTrue(marked.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["1 to mine"].exists)
        marked.descendants(matching: .any)["subtitle.line"].firstMatch.tap()
        XCTAssertTrue(app.buttons["lookup.playClip"].waitForExistence(timeout: 5))
        app.closeLookup()
        XCTAssertTrue(app.buttons["mark.clear"].waitForExistence(timeout: 5))
        app.buttons["mark.clear"].tap()
        XCTAssertTrue(app.staticTexts["Marks you make while listening show up here."].waitForExistence(timeout: 5))
    }

    func testStatsShowsTimeListened() {
        let app = XCUIApplication()
        app.launchEnvironment = ["UITEST_KIKU": "1", "UITEST_STATS": "1"]
        app.launch()
        app.tabBars.buttons["Stats"].tap()
        XCTAssertTrue(app.staticTexts["Time listened"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["stats.series"].firstMatch.exists)
    }
}
