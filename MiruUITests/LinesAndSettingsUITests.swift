import XCTest

/// From #165, in memory (`UITEST_PLAYER`): Settings ▸ Subtitles ▸ Kaku opens and goes back the
/// way it came, and Lines' search says "No Results" only once a search has run.
final class LinesAndSettingsUITests: XCTestCase {
    func testSubtitlesKakuTapThrough() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["UITEST_MUTE"] = "1"
        app.launchEnvironment["UITEST_PLAYER"] = "1"
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        app.tabBars.buttons["Settings"].tap()
        let subtitles = app.descendants(matching: .any)["settings.subtitles"].firstMatch
        XCTAssertTrue(subtitles.waitForExistence(timeout: 10))
        subtitles.tap()
        let kaku = app.descendants(matching: .any)["subtitles.kaku"].firstMatch
        XCTAssertTrue(kaku.waitForExistence(timeout: 5))
        kaku.tap()
        XCTAssertTrue(app.navigationBars["Kaku"].waitForExistence(timeout: 5), "Kaku's page")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Subtitles"].waitForExistence(timeout: 5), "back to Subtitles")
        XCTAssertTrue(kaku.isHittable, "and Kaku opens again")
        kaku.tap()
        XCTAssertTrue(app.navigationBars["Kaku"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5), "back to Settings")
    }

    func testLinesSaysNoResultsOnlyAfterSearching() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["UITEST_MUTE"] = "1"
        app.launchEnvironment["UITEST_PLAYER"] = "1"
        app.launchEnvironment["UITEST_TRANSCRIPT"] = "1"
        app.launch()
        app.tabBars.buttons["Lines"].tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        let noResults = app.descendants(matching: .any)["lines.noResults"].firstMatch
        // A word the saved subtitles have: "No Results" never shows while the search runs.
        field.typeText("猫")
        for _ in 0..<6 {
            XCTAssertFalse(noResults.exists, "no flash of No Results before the search ran")
            usleep(100_000)
        }
        XCTAssertTrue(app.descendants(matching: .any)["lines.result"].firstMatch.waitForExistence(timeout: 5))
        // One they don't: it shows once searched.
        field.typeText(XCUIKeyboardKey.delete.rawValue)
        field.typeText("鯨")
        XCTAssertTrue(noResults.waitForExistence(timeout: 5), "No Results after the search")
    }

    /// #166 in Miru: two screens deep in Settings, tapping the Settings tab again shows its top.
    @MainActor
    func testSettingsTabReturnsToTheTopFromTwoScreensDeep() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["UITEST_MUTE"] = "1"
        app.launchEnvironment["UITEST_PLAYER"] = "1"
        app.launch()
        checkSettingsTabRetap(app)
    }

    /// Lines' stack is driven by a path of its own (`LinesView.reset`): an episode open, tapping
    /// Lines again shows its top, and the next tap opens an episode.
    @MainActor
    func testLinesTabReturnsToTheTop() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["UITEST_MUTE"] = "1"
        app.launchEnvironment["UITEST_PLAYER"] = "1"
        app.launchEnvironment["UITEST_TRANSCRIPT"] = "1"
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        let tab = app.tabBars.buttons["Lines"]
        tab.tap()
        let episode = app.buttons["lines.episode"].firstMatch
        XCTAssertTrue(episode.waitForExistence(timeout: 15))
        episode.tap()
        XCTAssertTrue(episode.waitForNonExistence(timeout: 5), "the episode open")
        sleep(1)
        tab.tap()
        XCTAssertTrue(episode.waitForExistence(timeout: 5), "the top of Lines")
        XCTAssertTrue(episode.isHittable)
        episode.tap()
        XCTAssertTrue(episode.waitForNonExistence(timeout: 5), "the next tap opens it")
    }

    /// Side by side (a wide screen: an iPhone sideways, the Duo open), picking another episode
    /// replaces the right side; the list on the left stays where it is (it slid out and back).
    @MainActor
    func testWideLinesListStaysPutWhenPickingAnEpisode() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["UITEST_MUTE"] = "1"
        app.launchEnvironment["UITEST_PLAYER"] = "1"
        app.launchEnvironment["UITEST_TRANSCRIPT"] = "2"
        app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        sleep(1)
        app.buttons["Lines"].firstMatch.tap()
        let episodes = app.buttons.matching(identifier: "lines.episode")
        XCTAssertTrue(episodes.element(boundBy: 1).waitForExistence(timeout: 15), "two episodes")
        func line(_ text: String) -> XCUIElement { app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch }
        XCTAssertTrue(line("吾輩は猫").waitForExistence(timeout: 10), "wide: the latest is open on the right")
        episodes.element(boundBy: 1).tap()
        XCTAssertTrue(line("親譲り").waitForExistence(timeout: 5), "the second episode on the right")
        XCTAssertTrue(episodes.element(boundBy: 0).isHittable, "the list is still there")
        // The left side never pushed a screen of its own (it slid away and back, too quick to
        // see in the tree: the debug count says).
        let pushes = app.descendants(matching: .any)["split.leftPushes"].firstMatch
        XCTAssertTrue(pushes.exists, "a debug build")
        XCTAssertEqual(pushes.value as? String, "0", "the list slid out and back")
    }
}
