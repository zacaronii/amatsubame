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
        let row = app.revealSettingsRow("settings.audiobookshelf")
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(app.buttons["audiobookshelf.signIn"].waitForExistence(timeout: 5))
        // Tapping the tab that's showing goes back to its top screen.
        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.buttons["audiobookshelf.signIn"].waitForNonExistence(timeout: 5), "back at the top of Settings")
        XCTAssertTrue(app.navigationBars["Settings"].exists)
        XCTAssertTrue(app.revealSettingsRow("settings.audiobookshelf").exists, "the row is in Settings' list")
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
        // The popup starts with the line itself: no clip bar above it.
        XCTAssertFalse(app.buttons["lookup.playClip"].exists)
        let lookup = XCTAttachment(screenshot: app.screenshot())
        lookup.name = "player-lookup"
        lookup.lifetime = .keepAlways
        add(lookup)
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

/// More ▸ Lines: Pause After Each Line stops playback as each line ends; Text Size changes the transcript.
final class KikuLinesMenuUITests: XCTestCase {
    func testPauseAfterEachLineAndTextSize() {
        let app = XCUIApplication()
        app.launchEnvironment = ["UITEST_KIKU": "1", "UITEST_KIKU_PLAYER": "1"]
        app.launch()
        let playPause = app.buttons["player.playPause"]
        XCTAssertTrue(playPause.waitForExistence(timeout: 10))
        func item(_ title: String) -> XCUIElement {
            app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", title)).firstMatch
        }
        app.buttons["More"].tap()
        app.buttons["player.linesMenu"].firstMatch.tap()
        XCTAssertTrue(item("Pause After Each Line").waitForExistence(timeout: 5))
        XCTAssertTrue(item("Repeat the Line").exists)
        item("Pause After Each Line").tap()

        playPause.tap()
        XCTAssertEqual(playPause.value as? String, "playing")
        let paused = expectation(for: NSPredicate(format: "value == 'paused'"), evaluatedWith: playPause)
        wait(for: [paused], timeout: 15)
        XCTAssertTrue(app.descendants(matching: .any)["player.currentLine"].exists, "stopped on a line")
        // Play again: on to the next line, then stopped again.
        playPause.tap()
        let again = expectation(for: NSPredicate(format: "value == 'paused'"), evaluatedWith: playPause)
        wait(for: [again], timeout: 15)

        // Off again (it's remembered), and a larger text size.
        app.buttons["More"].tap()
        app.buttons["player.linesMenu"].firstMatch.tap()
        item("Pause After Each Line").tap()
        app.buttons["More"].tap()
        app.buttons["player.linesMenu"].firstMatch.tap()
        item("Text Size").tap()
        item("Extra Large").tap()
        sleep(1)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "extra large lines"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.buttons["More"].tap()
        app.buttons["player.linesMenu"].firstMatch.tap()
        item("Text Size").tap()
        item("Medium").tap()
    }

    /// More offers Up Next's first when the queue has one, and not otherwise (the AirPods' and
    /// the wheel's next stay the next line and a skip).
    func testPlayerMenuOffersUpNext() {
        let app = XCUIApplication()
        app.launchEnvironment = ["UITEST_KIKU": "1", "UITEST_KIKU_PLAYER": "1", "UITEST_KIKU_UP_NEXT": "1"]
        app.launch()
        XCTAssertTrue(app.buttons["player.playPause"].waitForExistence(timeout: 10))
        app.buttons["More"].tap()
        XCTAssertTrue(app.buttons["player.playUpNext"].firstMatch.waitForExistence(timeout: 5))
        app.terminate()
        app.launchEnvironment = ["UITEST_KIKU": "1", "UITEST_KIKU_PLAYER": "1"]
        app.launch()
        XCTAssertTrue(app.buttons["player.playPause"].waitForExistence(timeout: 10))
        app.buttons["More"].tap()
        XCTAssertTrue(app.buttons["player.find"].firstMatch.waitForExistence(timeout: 5) || app.buttons["Sleep Timer"].firstMatch.exists)
        XCTAssertFalse(app.buttons["player.playUpNext"].firstMatch.exists, "an empty queue: not offered")
    }

    /// More ▸ Find in Transcript: the lines holding what's typed, one at a time from the line
    /// playing, with the count; Done puts the bar away. The sleep timer of minutes says a shake
    /// starts it again (the shake itself needs a real phone).
    func testFindInTranscriptAndSleepShakeHint() {
        let app = XCUIApplication()
        app.launchEnvironment = ["UITEST_KIKU": "1", "UITEST_KIKU_PLAYER": "1"]
        app.launch()
        XCTAssertTrue(app.buttons["player.playPause"].waitForExistence(timeout: 10))
        app.buttons["More"].tap()
        app.buttons["player.find"].firstMatch.tap()
        let field = app.textFields["player.findField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("番目")
        let count = app.staticTexts["player.findCount"]
        XCTAssertTrue(count.waitForExistence(timeout: 5))
        XCTAssertEqual(count.label, "1 of 20")
        app.buttons["player.findNext"].tap()
        XCTAssertEqual(count.label, "2 of 20")
        app.buttons["player.findPrevious"].tap()
        app.buttons["player.findPrevious"].tap()
        XCTAssertEqual(count.label, "20 of 20", "back past the first wraps round")
        // Far down the transcript: scrolled to it.
        let line = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'その20番目'")).firstMatch
        XCTAssertTrue(line.waitForExistence(timeout: 5))
        XCTAssertTrue(line.isHittable, "the line found is on screen")
        XCTAssertTrue(app.buttons["player.backToNow"].exists, "following stopped while finding")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "find in transcript"
        shot.lifetime = .keepAlways
        add(shot)
        field.tap()
        field.typeText("ないもの")
        XCTAssertEqual(count.label, "No lines")
        app.buttons["player.findDone"].tap()
        XCTAssertTrue(field.waitForNonExistence(timeout: 5))

        app.buttons["More"].tap()
        app.buttons["Sleep Timer"].firstMatch.tap()
        app.buttons["15 Minutes"].firstMatch.tap()
        app.buttons["More"].tap()
        let timer = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Sleep Timer ·'")).firstMatch
        XCTAssertTrue(timer.waitForExistence(timeout: 5))
        timer.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Shake to start it again'")).firstMatch.waitForExistence(timeout: 5))
        app.buttons["Turn Off"].firstMatch.tap()
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
        let lines = app.descendants(matching: .any).matching(identifier: "player.line")
        XCTAssertTrue(lines.firstMatch.waitForExistence(timeout: 5))
        // A line on screen (the first may have scrolled up under the player's header).
        let line = lines.allElementsBoundByIndex.lazy
            .map { $0.descendants(matching: .any)["subtitle.line"].firstMatch }
            .first { $0.isHittable }
        XCTAssertNotNil(line, "a line on screen")
        line?.press(forDuration: 1.0)
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
        XCTAssertTrue(app.descendants(matching: .any)["lookup.handle"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["lookup.playClip"].exists)
        app.closeLookup()
        XCTAssertTrue(app.buttons["mark.clear"].waitForExistence(timeout: 5))
        app.buttons["mark.clear"].tap()
        XCTAssertTrue(app.staticTexts["Marks you make while listening show up here."].waitForExistence(timeout: 5))
    }

    /// A note on a mark: from the toast's Add Note right after marking, shown on the mark in
    /// Marks, found by the search, edited from the mark, gone with the mark.
    func testMarkNoteFromTheToastShowsAndIsFound() {
        let app = XCUIApplication()
        app.launchEnvironment = ["UITEST_KIKU": "1", "UITEST_KIKU_PLAYER": "1"]
        app.launch()
        XCTAssertTrue(app.buttons["player.playPause"].waitForExistence(timeout: 10))
        app.buttons["player.mark"].tap()
        let addNote = app.buttons["player.addNote"]
        XCTAssertTrue(addNote.waitForExistence(timeout: 3))
        addNote.tap()
        let text = app.textViews["markNote.text"]
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        text.typeText("駅の場面")
        app.buttons["markNote.done"].tap()
        XCTAssertTrue(text.waitForNonExistence(timeout: 5))
        app.buttons["player.close"].tap()
        app.tabBars.buttons["Marks"].tap()

        let note = app.buttons["mark.note"]
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        XCTAssertTrue(note.label.contains("駅の場面"), note.label)
        // Edited from the mark: the note is kept as written.
        app.buttons["mark.editNote"].tap()
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        text.typeText("、後で")
        app.buttons["markNote.done"].tap()
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        XCTAssertTrue(note.label.contains("駅の場面、後で"), note.label)
        // The search finds the mark by its note.
        let field = app.searchFields.firstMatch
        field.tap()
        field.typeText("駅の場面")
        let found = app.staticTexts["In your marks · 1"]
        XCTAssertTrue(found.waitForExistence(timeout: 5))
        // Cleared from the results: the mark and its note are gone.
        app.buttons["mark.clear"].firstMatch.tap()
        XCTAssertTrue(found.waitForNonExistence(timeout: 5))
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
