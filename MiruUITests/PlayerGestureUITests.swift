import XCTest

/// Player gestures on a local test video (`TEST_RUNNER_UITEST_PLAYER_VIDEO=<path>`; skipped without it).
final class PlayerGestureUITests: XCTestCase {
    func testTwoFingerTapDoubleTapAndScrub() throws {
        guard let video = ProcessInfo.processInfo.environment["UITEST_PLAYER_VIDEO"] else {
            throw XCTSkip("Set TEST_RUNNER_UITEST_PLAYER_VIDEO to a video file to test gestures.")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["UITEST_PLAYER"] = "1"
        app.launchEnvironment["UITEST_PLAYER_VIDEO"] = video
        app.launch()

        let player = app.descendants(matching: .any)["player.video"].firstMatch
        XCTAssertTrue(player.waitForExistence(timeout: 10))
        func state() -> (time: Double, paused: Bool) {
            let value = player.value as? String ?? ""
            return (Double(value.split(separator: " ").first ?? "") ?? -1, value.hasSuffix("paused"))
        }
        let playing = expectation(for: NSPredicate { _, _ in state().time > 2 && !state().paused }, evaluatedWith: nil)
        wait(for: [playing], timeout: 15)

        // Two-finger tap pauses (and again resumes) without bringing up the controls.
        let close = app.buttons["player.close"]
        XCTAssertTrue(close.waitForNonExistence(timeout: 8), "controls hide while playing")
        player.twoFingerTap()
        sleep(1)
        XCTAssertTrue(state().paused, "two-finger tap pauses")
        XCTAssertFalse(close.exists, "a two-finger pause leaves the controls hidden")
        XCTAssertFalse(app.buttons["player.playPause"].exists, "and shows no play button")
        let start = state().time

        // Double-tap the right third twice: +20 s.
        let right = player.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5))
        right.doubleTap()
        right.doubleTap()
        sleep(1)
        XCTAssertEqual(state().time, start + 20, accuracy: 1.5, "double-taps on the right add up")

        // Double-tap the left third: −10 s.
        player.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)).doubleTap()
        sleep(1)
        XCTAssertEqual(state().time, start + 10, accuracy: 1.5, "double-tap on the left goes back")

        // Drag left to right across half the width: a 60 s clip covers 15 s per width, so about +7.5 s.
        let before = state().time
        player.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: player.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5)))
        sleep(1)
        XCTAssertEqual(state().time, before + 7.5, accuracy: 2, "scrubbing seeks by the drag")

        player.twoFingerTap()
        sleep(1)
        XCTAssertFalse(state().paused, "two-finger tap resumes")
    }

    func testSkipIntroButton() throws {
        guard let video = ProcessInfo.processInfo.environment["UITEST_PLAYER_VIDEO"] else {
            throw XCTSkip("Set TEST_RUNNER_UITEST_PLAYER_VIDEO to a video file to test skipping.")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["UITEST_PLAYER"] = "1"
        app.launchEnvironment["UITEST_PLAYER_VIDEO"] = video
        app.launchEnvironment["UITEST_PLAYER_SEGMENTS"] = "Intro:0:30"
        app.launch()

        let player = app.descendants(matching: .any)["player.video"].firstMatch
        XCTAssertTrue(player.waitForExistence(timeout: 10))
        // The button shows by itself during the intro, even once the controls hide.
        let skip = app.buttons["player.skip"]
        XCTAssertTrue(skip.waitForExistence(timeout: 10))
        XCTAssertEqual(skip.label, "Skip Intro")
        skip.tap()
        func skipped() -> XCTWaiter.Result {
            let past = expectation(for: NSPredicate { _, _ in
                Double((player.value as? String ?? "").split(separator: " ").first ?? "") ?? 0 >= 29
            }, evaluatedWith: nil)
            return XCTWaiter().wait(for: [past], timeout: 3)
        }
        // The button moves down when the controls hide; a tap at that moment lands on the video.
        var result = skipped()
        if result != .completed, skip.exists {
            skip.tap()
            // Seeking is slow while the whole suite loads the simulator.
            for _ in 0..<4 where result != .completed { result = skipped() }
        }
        XCTAssertEqual(result, .completed, "didn't skip: \(player.value ?? "")")
        XCTAssertTrue(skip.waitForNonExistence(timeout: 5), "the button goes once the intro is over")
    }

    /// opening part-way in (past the intro), the time reads 0 for a moment while
    /// loading; the Skip Intro button mustn't flash then. A local file loads too fast to show
    /// the flash reliably (Jellyfin streams take seconds), so this mainly guards the
    /// part-way start; the fix is `MPVController.hasStarted`.
    func testSkipIntroDoesNotFlashWhenResumingPastTheIntro() throws {
        guard let video = ProcessInfo.processInfo.environment["UITEST_PLAYER_VIDEO"] else {
            throw XCTSkip("Set TEST_RUNNER_UITEST_PLAYER_VIDEO to a video file to test segments.")
        }
        let app = XCUIApplication()
        app.launchEnvironment["UITEST_PLAYER"] = "1"
        app.launchEnvironment["UITEST_PLAYER_VIDEO"] = video
        app.launchEnvironment["UITEST_PLAYER_SEGMENTS"] = "Intro:0:30"
        app.launchEnvironment["UITEST_PLAYER_START"] = "40"
        app.launch()
        let skip = app.buttons["player.skip"]
        // Watch the whole load: the button must never show.
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            XCTAssertFalse(skip.exists, "Skip Intro flashed while loading")
            if skip.exists { break }
        }
        let player = app.descendants(matching: .any)["player.video"].firstMatch
        XCTAssertTrue(player.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(Double((player.value as? String ?? "").split(separator: " ").first ?? "") ?? 0, 39)
    }

    /// a lookup pauses without bringing up the controls, and closing the popup plays
    /// again; if it was already paused, it stays paused.
    func testLookupPausesQuietlyAndClosingResumes() throws {
        guard let video = ProcessInfo.processInfo.environment["UITEST_PLAYER_VIDEO"] else {
            throw XCTSkip("Set TEST_RUNNER_UITEST_PLAYER_VIDEO to a video file to test lookups.")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["UITEST_PLAYER"] = "1"
        app.launchEnvironment["UITEST_PLAYER_VIDEO"] = video
        app.launchEnvironment["UITEST_JIMAKU"] = "1"
        app.launch()
        // Subtitles from the canned Jimaku answer (lines of about 20 s).
        let find = app.buttons["player.noSubtitles"]
        XCTAssertTrue(find.waitForExistence(timeout: 10))
        find.tap()
        let file = app.buttons.matching(identifier: "subtitles.file").firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: 10))
        file.tap()
        let line = app.descendants(matching: .any).matching(identifier: "subtitle.line").firstMatch
        XCTAssertTrue(line.waitForExistence(timeout: 10))
        let player = app.descendants(matching: .any)["player.video"].firstMatch
        let playPause = app.buttons["player.playPause"]
        func isPlaying() -> Bool { (player.value as? String ?? "").hasSuffix("playing") }

        // Playing, controls hidden.
        if !isPlaying() {
            if !playPause.exists { player.tap() }
            XCTAssertTrue(playPause.waitForExistence(timeout: 5))
            playPause.tap()
        }
        XCTAssertTrue(playPause.waitForNonExistence(timeout: 8), "the controls hide while playing")
        XCTAssertTrue(isPlaying())

        line.tap()
        let popup = app.descendants(matching: .any)["player.lookup"].firstMatch
        XCTAssertTrue(popup.waitForExistence(timeout: 5))
        XCTAssertFalse(isPlaying(), "a lookup pauses")
        sleep(1)
        XCTAssertFalse(playPause.exists, "without bringing up the controls")
        // Tapping beside the popup closes it straight away (no double-tap wait) and plays again.
        player.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.2)).tap()
        XCTAssertTrue(popup.waitForNonExistence(timeout: 0.4), "the popup closes without the double-tap delay")
        let playing = expectation(for: NSPredicate { _, _ in isPlaying() }, evaluatedWith: nil)
        wait(for: [playing], timeout: 5)

        // Paused by hand first: after a lookup it stays paused.
        player.tap()
        XCTAssertTrue(playPause.waitForExistence(timeout: 5))
        playPause.tap()
        XCTAssertFalse(isPlaying())
        line.tap()
        XCTAssertTrue(popup.waitForExistence(timeout: 5))
        player.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.2)).tap()
        XCTAssertTrue(popup.waitForNonExistence(timeout: 5))
        sleep(1)
        XCTAssertFalse(isPlaying(), "it was paused before the lookup")
    }

    /// near the end the Up Next card shows; when its countdown runs out the next
    /// episode plays. Cancel hides it.
    func testUpNextCardPlaysTheNextEpisodeOrCancels() throws {
        guard let video = ProcessInfo.processInfo.environment["UITEST_PLAYER_VIDEO"] else {
            throw XCTSkip("Set TEST_RUNNER_UITEST_PLAYER_VIDEO to a video file to test Up Next.")
        }
        continueAfterFailure = false
        func launch() -> XCUIApplication {
            let app = XCUIApplication()
            app.launchEnvironment["UITEST_PLAYER"] = "1"
            app.launchEnvironment["UITEST_PLAYER_VIDEO"] = video
            // The test video is 60 s: the card comes 20 s before the end.
            app.launchEnvironment["UITEST_PLAYER_START"] = "41"
            app.launchEnvironment["UITEST_PLAYER_FOLLOWING"] = video
            app.launch()
            return app
        }
        var app = launch()
        let card = app.descendants(matching: .any)["player.upNext"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10), "the Up Next card shows near the end")
        XCTAssertTrue(app.staticTexts["Next Test Video"].exists)
        // The countdown (10 s) plays the next one, from its start.
        XCTAssertTrue(card.waitForNonExistence(timeout: 16))
        let player = app.descendants(matching: .any)["player.video"].firstMatch
        let restarted = expectation(for: NSPredicate { _, _ in
            (Double((player.value as? String ?? "").split(separator: " ").first ?? "") ?? 99) < 15
        }, evaluatedWith: nil)
        wait(for: [restarted], timeout: 10)

        app.terminate()
        app = launch()
        let again = app.descendants(matching: .any)["player.upNext"].firstMatch
        XCTAssertTrue(again.waitForExistence(timeout: 10))
        app.buttons["player.upNextCancel"].tap()
        XCTAssertTrue(again.waitForNonExistence(timeout: 3))
        sleep(4)
        XCTAssertFalse(again.exists, "cancelled stays hidden")
    }

    /// playback goes on in the background (audio only). Needs a test video with sound
    /// (UITEST_PLAYER_AUDIO_VIDEO).
    func testBackgroundAudioAndNowPlaying() throws {
        guard let video = ProcessInfo.processInfo.environment["UITEST_PLAYER_AUDIO_VIDEO"] else {
            throw XCTSkip("Set TEST_RUNNER_UITEST_PLAYER_AUDIO_VIDEO to a video with an audio track.")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["UITEST_PLAYER"] = "1"
        app.launchEnvironment["UITEST_PLAYER_VIDEO"] = video
        app.launch()
        let player = app.descendants(matching: .any)["player.video"].firstMatch
        XCTAssertTrue(player.waitForExistence(timeout: 10))
        sleep(3)
        func time() -> Double { Double((player.value as? String ?? "").split(separator: " ").first ?? "") ?? 0 }
        let before = time()
        XCUIDevice.shared.press(.home)
        sleep(6)
        // (The simulator's Control Center has no Now Playing module; the app's nowplaying.log
        // records what it told the system, read from the container.)
        app.activate()
        XCTAssertTrue(player.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(time(), before + 5, "it kept playing in the background")
        // mpv's iOS audio output mixes with other apps unless told otherwise, and then AirPods
        // and Control Center go to other apps.
        XCTAssertFalse((player.value as? String ?? "").contains("mixing"), "the audio session mixes: \(player.value ?? "")")
    }

    func testFindSubtitlesOnJimakuRetimeAndSave() throws {
        guard let video = ProcessInfo.processInfo.environment["UITEST_PLAYER_VIDEO"] else {
            throw XCTSkip("Set TEST_RUNNER_UITEST_PLAYER_VIDEO to a video file to test subtitle search.")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["UITEST_PLAYER"] = "1"
        app.launchEnvironment["UITEST_PLAYER_VIDEO"] = video
        app.launchEnvironment["UITEST_JIMAKU"] = "1"
        app.launchEnvironment["UITEST_SYNC_REFERENCE"] = "1"
        app.launch()

        // No Japanese subtitles: the label is the way in.
        let find = app.buttons["player.noSubtitles"]
        XCTAssertTrue(find.waitForExistence(timeout: 10))
        find.tap()
        // One show matches, so its files show straight away; the .rar can't be opened.
        let files = app.buttons.matching(identifier: "subtitles.file")
        XCTAssertTrue(files.firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(files.count, 2)
        XCTAssertFalse(files.element(boundBy: 1).isEnabled, "rar files can't be opened")
        files.element(boundBy: 0).tap()

        // Back in the player with the file's lines; the timing is in the Subtitles sheet.
        let line = app.descendants(matching: .any).matching(identifier: "subtitle.line").firstMatch
        XCTAssertTrue(line.waitForExistence(timeout: 10), "the picked subtitles show")
        let player = app.descendants(matching: .any)["player.video"].firstMatch
        let subtitles = app.buttons["player.subtitles"]
        if !subtitles.exists { player.tap() }
        XCTAssertTrue(subtitles.waitForExistence(timeout: 5))
        let controls = XCTAttachment(screenshot: app.screenshot())
        controls.name = "player-controls"
        controls.lifetime = .keepAlways
        add(controls)
        subtitles.tap()
        XCTAssertTrue(app.buttons["subtitles.track"].firstMatch.waitForExistence(timeout: 5), "the Jimaku file is the track")
        let timing = app.staticTexts["player.subtitleTiming"]
        let later = app.buttons["1 s Later"]
        XCTAssertTrue(later.waitForExistence(timeout: 5))
        later.tap()
        sleep(4)
        XCTAssertTrue(later.exists, "the sheet stays while retiming")
        XCTAssertEqual(timing.value as? String, "+1.0 s")
        let sheet = XCTAttachment(screenshot: app.screenshot())
        sheet.name = "subtitles-sheet"
        sheet.lifetime = .keepAlways
        add(sheet)

        // Auto-Sync lines the file up with the reference (the lines 2 s later), replacing the
        // manual step; Reset goes back to the download.
        app.buttons["player.autoSync"].tap()
        let result = app.staticTexts["player.syncResult"]
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        XCTAssertEqual(result.label, "Synced to the test reference: moved 2.0 s later")
        XCTAssertEqual(timing.value as? String, "Synced")
        app.buttons["player.resetTiming"].tap()
        XCTAssertEqual(timing.value as? String, "0.0 s")
        XCTAssertFalse(result.exists)
        app.buttons["player.autoSync"].tap()
        XCTAssertTrue(result.waitForExistence(timeout: 10))

        // Saving to Jellyfin asks first; cancelling leaves nothing queued.
        let save = app.buttons["player.saveSubtitles"]
        // Below the timing: swipe the sheet up to it.
        for _ in 0..<3 where !(save.exists && save.isHittable) { app.swipeUp() }
        XCTAssertTrue(save.exists)
        XCTAssertTrue(save.label.hasPrefix("Save to Jellyfin…"), save.label)
        save.tap()
        let confirm = app.buttons["player.confirmSaveSubtitles"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        // iPhone shows it as a sheet or popover without a Cancel button: dismiss it.
        let dismiss = app.otherElements["PopoverDismissRegion"]
        if dismiss.exists { dismiss.tap() } else if app.buttons["Cancel"].exists { app.buttons["Cancel"].tap() }
        XCTAssertTrue(confirm.waitForNonExistence(timeout: 5))
        XCTAssertTrue(save.label.hasPrefix("Save to Jellyfin…"), save.label)
        save.tap()
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Waiting to Save to Jellyfin'")).firstMatch
            .waitForExistence(timeout: 5))

        // One upload is queued (retimed); nothing more goes when the episode closes.
        app.buttons["Done"].firstMatch.tap()
        let close = app.buttons["player.close"]
        if !close.waitForExistence(timeout: 3) { player.tap() }
        close.tap()
        app.tabBars.buttons["Settings"].tap()
        let queue = app.staticTexts["Queue"].firstMatch
        for _ in 0..<8 where !queue.waitForExistence(timeout: 2) { app.swipeUp() }
        queue.tap()
        XCTAssertTrue(app.staticTexts["Jellyfin subtitles"].firstMatch.waitForExistence(timeout: 5), "upload queued")
        XCTAssertEqual(app.staticTexts.matching(identifier: "Jellyfin subtitles").count, 1)
    }
}
