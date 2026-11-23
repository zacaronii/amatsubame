import XCTest

/// Watch's stack is driven by a path of its own: two screens deep (a library ▸ a show), tapping
/// Watch again shows its top, and the next tap opens the library. Needs Miru signed in on the
/// simulator (`DevSetup`, docs/shared.md); skipped otherwise.
final class WatchRetapUITests: XCTestCase {
    @MainActor
    func testWatchTabReturnsToTheTopFromTwoScreensDeep() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        let libraries = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'library.' AND identifier != 'library.filter'"))
        guard libraries.firstMatch.waitForExistence(timeout: 20) else { throw XCTSkip("Sign Miru in to Jellyfin on the simulator (DevSetup).") }
        let library = libraries.firstMatch
        let name = library.identifier
        library.tap()
        let show = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'series.' AND identifier != 'series.season' AND identifier != 'series.downloads' AND identifier != 'series.facts'")).firstMatch
        XCTAssertTrue(show.waitForExistence(timeout: 20), "the library's shows")
        show.tap()
        XCTAssertTrue(app.descendants(matching: .any)["series.facts"].firstMatch.waitForExistence(timeout: 20)
                      || app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'episode.'")).firstMatch.waitForExistence(timeout: 10),
                      "the show, two screens deep")
        sleep(1)
        app.tabBars.buttons["Watch"].tap()
        let row = app.buttons[name].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5) && row.isHittable, "the top of Watch")
        row.tap()
        XCTAssertTrue(show.waitForExistence(timeout: 20), "the next tap opens the library")
    }
}
