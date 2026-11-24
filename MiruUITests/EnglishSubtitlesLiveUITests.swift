import XCTest

/// English Subtitles on, off and on again on a streamed episode whose English is in the file
/// (Jellyfin serves it as a separate subtitle). Live: needs Miru signed in to a test account
/// (`DevSetup`, docs/shared.md) and `TEST_RUNNER_UITEST_ENGLISH_QUERY` (finds such a show).
final class EnglishSubtitlesLiveUITests: XCTestCase {
    func testEnglishSubtitlesTurnOffWhileStreaming() throws {
        guard let query = ProcessInfo.processInfo.environment["UITEST_ENGLISH_QUERY"] else {
            throw XCTSkip("Set TEST_RUNNER_UITEST_ENGLISH_QUERY.")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let search = app.buttons["watch.search"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 20), "signed in to Jellyfin")
        search.tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText(query)
        let result = app.descendants(matching: .any)["search.result"].firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 15), "something found")
        result.tap()
        let play = app.descendants(matching: .any)["series.play"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 15), "the show's page")
        play.tap()
        let player = app.descendants(matching: .any)["player.video"].firstMatch
        XCTAssertTrue(player.waitForExistence(timeout: 20), "the player")
        // Past the opening, where there are lines.
        sleep(5)
        checkEnglishTurnsOnAndOff(app, player: player)
        app.buttons["player.close"].firstMatch.tap()
    }
}
