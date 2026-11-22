import XCTest

/// Watch ▸ Search against a real Jellyfin (#145): choosing a result opens it and it stays open.
/// Needs Miru already signed in on the simulator (`DevSetup`, docs/shared.md) and
/// `TEST_RUNNER_UITEST_SEARCH_QUERY` (text that finds a show or movie there).
final class SearchUITests: XCTestCase {
    func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testChoosingAResultLeavesSearch() throws {
        guard let query = ProcessInfo.processInfo.environment["UITEST_SEARCH_QUERY"] else {
            throw XCTSkip("Set TEST_RUNNER_UITEST_SEARCH_QUERY.")
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
        shot(app, "results")
        result.tap()

        // The show or movie comes up, and is still there a few seconds on.
        let results = app.descendants(matching: .any).matching(identifier: "search.result")
        XCTAssertTrue(result.waitForNonExistence(timeout: 5), "search is left")
        shot(app, "chosen")
        sleep(4)
        shot(app, "a few seconds on")
        XCTAssertEqual(results.count, 0, "and it doesn't come back")
        XCTAssertFalse(app.keyboards.firstMatch.exists, "the keyboard has gone")

        // Back goes to the results, as they were.
        app.navigationBars.buttons["BackButton"].firstMatch.tap()
        XCTAssertTrue(result.waitForExistence(timeout: 5), "Back returns to the results")
    }
}
