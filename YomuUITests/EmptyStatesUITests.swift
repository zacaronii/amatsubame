import XCTest

/// A newcomer's empty tabs each offer a way forward (public beta): no server and no
/// dictionaries, after Set Up Later.
final class EmptyStatesUITests: XCTestCase {
    private func skippedSetup() -> XCUIApplication {
        let app = XCUIApplication.setup(data: "yomu-empty-\(UUID().uuidString.prefix(8))")
        app.launch()
        XCTAssertTrue(app.buttons["setup.later"].waitForExistence(timeout: 20))
        app.buttons["setup.later"].tap()
        XCTAssertTrue(app.alerts.buttons["Skip"].waitForExistence(timeout: 5))
        app.alerts.buttons["Skip"].tap()
        // The alert is still leaving for a moment: a tab tapped then doesn't switch.
        XCTAssertTrue(app.alerts.firstMatch.waitForNonExistence(timeout: 5))
        sleep(1)
        return app
    }

    func testNoServerOpensSettings() {
        let app = skippedSetup()
        let button = app.buttons["library.openSettings"]
        XCTAssertTrue(button.waitForExistence(timeout: 10), "the empty tab has Open Settings")
        button.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10), "and it opens Settings")
    }

    func testNoDictionariesOffersTheRecommended() {
        let app = skippedSetup()
        app.tabBars.buttons["Dictionary"].tap()
        XCTAssertTrue(app.navigationBars["Dictionary"].waitForExistence(timeout: 10))
        let button = app.descendants(matching: .any)["search.addRecommended"].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 10), "No Dictionaries has Add Recommended")
        button.tap()
        XCTAssertTrue(app.navigationBars["Recommended"].waitForExistence(timeout: 10), "and it lists them")
        XCTAssertTrue(app.buttons["recommended.download"].exists)
    }
}
