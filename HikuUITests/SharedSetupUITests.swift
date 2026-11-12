import XCTest

/// With the App Group (simulator builds), Hiku fills in its setup from the other
/// apps: set TEST_RUNNER_EXPECT_SHARED_DICTIONARY to a dictionary title another app imported
/// (e.g. with the Player's PLAYER_IMPORT_DICTIONARIES) to check it's listed here.
final class SharedSetupUITests: XCTestCase {
    func testDictionariesComeFromTheOtherApps() throws {
        guard let title = ProcessInfo.processInfo.environment["EXPECT_SHARED_DICTIONARY"] else {
            throw XCTSkip("Set TEST_RUNNER_EXPECT_SHARED_DICTIONARY to check the shared setup.")
        }
        let app = XCUIApplication()
        app.launch()
        let dictionaries = app.buttons["lookup.dictionaries"].firstMatch
        XCTAssertTrue(dictionaries.waitForExistence(timeout: 10), "the setup screens show (the App Group is there)")
        XCTAssertTrue(app.switches["setup.share"].firstMatch.exists, "sharing is offered")
        dictionaries.tap()
        let row = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "\(title) is listed")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "dictionaries"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
