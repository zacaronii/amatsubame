import XCTest

/// The beta's UI sweep (SharedUITests/SweepSupport.swift): every tab and Settings row, and a saved
/// transcript in Lines, each audited. In memory, with no server.
final class SweepUITests: XCTestCase {
    func testSweep() throws {
        let app = XCUIApplication()
        app.launchEnvironment["UITEST_PLAYER"] = "1"
        app.launchEnvironment["UITEST_TRANSCRIPT"] = "1"
        prepareSweep(app)
        app.launch()
        XCTAssertTrue(sweepTab(app, "Watch").waitForExistence(timeout: 20))
        sleep(2)
        var issues = sweepTabsAndSettings(app, prefix: "miru", tabs: ["Watch", "Lines", "Stats", "Settings"])
        sweepTab(app, "Lines").tap()
        let episode = app.buttons["lines.episode"].firstMatch
        if episode.waitForExistence(timeout: 10) {
            episode.tap()
            sleep(2)
            issues += auditScreen(app, "miru-lines-transcript")
        } else {
            print("SWEEP: miru · no saved transcript in Lines")
        }
        keepSweepIssues(issues, "miru-sweep-issues")
    }
}
