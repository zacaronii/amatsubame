import XCTest

/// The Player shell: Watch, Lines and Settings with the shared settings, in memory.
final class PlayerUITests: XCTestCase {
    func testTabsAndSettings() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["UITEST_PLAYER"] = "1"
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.descendants(matching: .any)["watch.placeholder"].waitForExistence(timeout: 10), "Watch tab")
        app.tabBars.buttons["Settings"].tap()
        for row in ["settings.jellyfin", "settings.libraries", "settings.subtitles", "settings.playback", "settings.downloads",
                    "settings.dictionaries", "settings.audioSources", "settings.anki", "settings.kechimochi", "settings.advanced"] {
            // Lower rows only exist once scrolled to.
            let element = app.descendants(matching: .any)[row].firstMatch
            for _ in 0..<4 where !element.waitForExistence(timeout: 2) {
                app.swipeUp()
            }
            XCTAssertTrue(element.exists, "\(row) in Settings")
        }
        // Skip intros under Playback, Card Picture on the Anki page.
        let playback = app.descendants(matching: .any)["settings.playback"].firstMatch
        for _ in 0..<4 where !playback.waitForExistence(timeout: 2) { app.swipeDown() }
        playback.tap()
        XCTAssertTrue(app.switches["settings.autoSkipIntros"].waitForExistence(timeout: 5), "Skip Intros in Playback")
        app.navigationBars.buttons.firstMatch.tap()
        let anki = app.descendants(matching: .any)["settings.anki"].firstMatch
        for _ in 0..<4 where !anki.isHittable { app.swipeUp() }
        anki.tap()
        XCTAssertTrue(app.staticTexts["Connection"].waitForExistence(timeout: 5), "the Anki page")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertFalse(app.staticTexts["Kavita"].exists, "Kavita belongs to the Reader")
        // Dictionary search is the Reader's; the Player gets a video-centric Lines tab in phase 7.
        XCTAssertFalse(app.tabBars.buttons["Search"].exists, "no Search tab in the Player")
        app.tabBars.buttons["Lines"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["lines.empty"].waitForExistence(timeout: 5), "Lines is empty without Jellyfin")
        XCTAssertFalse(app.tabBars.buttons["Downloads"].exists, "downloads live in Settings ▸ Storage")
        app.tabBars.buttons["Settings"].tap()
        let storage = app.buttons["settings.storage"].firstMatch
        for _ in 0..<4 where !storage.waitForExistence(timeout: 2) { app.swipeUp() }
        storage.tap()
        XCTAssertTrue(app.descendants(matching: .any)["storage.summary"].waitForExistence(timeout: 5), "the storage summary")
        XCTAssertTrue(app.staticTexts["Saved subtitles"].exists, "saved subtitles in Storage")
        app.descendants(matching: .any)["storage.downloads"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["downloads.empty"].waitForExistence(timeout: 5), "no downloads")
        XCTAssertTrue(app.descendants(matching: .any)["downloads.storage"].exists, "storage header")
    }

    /// The Stats tab with a few days of seeded watching (a screenshot to check by eye).
    func testStatsTab() throws {
        let app = XCUIApplication()
        app.launchEnvironment["UITEST_PLAYER"] = "1"
        app.launchEnvironment["UITEST_STATS"] = "1"
        app.launch()
        app.tabBars.buttons["Stats"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["stats.streak"].waitForExistence(timeout: 10), "streak shown")
        XCTAssertTrue(app.descendants(matching: .any)["stats.series"].firstMatch.exists, "by show")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "stats"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Word marks on a saved transcript, with the legend (a screenshot to check by eye; with no
    /// Anki set up every word is "not in Anki"). Needs `UITEST_DICTIONARY_ZIPS`.
    func testTranscriptShowsWordMarks() throws {
        guard let zips = ProcessInfo.processInfo.environment["UITEST_DICTIONARY_ZIPS"] else { throw XCTSkip("Needs UITEST_DICTIONARY_ZIPS.") }
        let app = XCUIApplication()
        app.launchEnvironment["UITEST_PLAYER"] = "1"
        app.launchEnvironment["UITEST_TRANSCRIPT"] = "1"
        app.launchEnvironment["UITEST_DICTIONARY_ZIPS"] = zips
        app.launch()
        app.tabBars.buttons["Lines"].tap()
        let episode = app.buttons["lines.episode"].firstMatch
        XCTAssertTrue(episode.waitForExistence(timeout: 30))
        sleep(15) // dictionaries import
        episode.tap()
        sleep(4)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "transcript-word-marks"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// One episode's lines: search within it, and each line's time plays from there.
    func testSearchThisEpisode() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["UITEST_PLAYER"] = "1"
        app.launchEnvironment["UITEST_TRANSCRIPT"] = "1"
        app.launch()
        app.tabBars.buttons["Lines"].tap()
        let episode = app.buttons["lines.episode"].firstMatch
        XCTAssertTrue(episode.waitForExistence(timeout: 5))
        episode.tap()
        let lines = app.descendants(matching: .any).matching(identifier: "subtitle.line")
        XCTAssertTrue(lines.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(identifier: "transcript.playLine").count, 3, "every line's time plays")
        XCTAssertEqual(app.buttons["transcript.playLine"].firstMatch.label, "Play from 0:01")
        let search = app.searchFields["Search this episode"].firstMatch
        if !search.waitForExistence(timeout: 2) { app.swipeDown() }
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("見当")
        XCTAssertTrue(app.staticTexts["1 line"].waitForExistence(timeout: 5))
        XCTAssertEqual(lines.count, 1)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "search-this-episode"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// A saved transcript is listed offline, opens as tappable lines and is searchable.
    func testSavedTranscriptInLines() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["UITEST_PLAYER"] = "1"
        app.launchEnvironment["UITEST_TRANSCRIPT"] = "1"
        app.launch()
        app.tabBars.buttons["Lines"].tap()
        let episode = app.buttons["lines.episode"].firstMatch
        XCTAssertTrue(episode.waitForExistence(timeout: 5), "saved episode listed")
        episode.tap()
        let lines = app.descendants(matching: .any).matching(identifier: "subtitle.line")
        XCTAssertTrue(lines.firstMatch.waitForExistence(timeout: 5), "lines shown")
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines.element(boundBy: 2).label, "どこで生れたかとんと見当がつかぬ。", "line breaks dropped for lookups")

        app.navigationBars.buttons.firstMatch.tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("見当")
        let result = app.descendants(matching: .any)["lines.result"].firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 5), "search finds the line")
        result.tap()
        XCTAssertTrue(lines.firstMatch.waitForExistence(timeout: 5), "result opens the transcript")
    }
}
