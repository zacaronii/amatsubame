import XCTest

/// From #165, in memory (`UITEST_PLAYER`): Settings ▸ Subtitles ▸ Kaku opens and goes back the
/// way it came, and Lines' search says "No Results" only once a search has run.
final class LinesAndSettingsUITests: XCTestCase {
    func testSubtitlesKakuTapThrough() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
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
}
