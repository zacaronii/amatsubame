import XCTest

/// The beta's UI sweep (SharedUITests/SweepSupport.swift): the player with a transcript, then every
/// tab and Settings row, each audited. In memory, with no server.
final class SweepUITests: XCTestCase {
    func testSweep() throws {
        let app = XCUIApplication()
        app.launchEnvironment = ["UITEST_KIKU": "1", "UITEST_KIKU_PLAYER": "1", "UITEST_MUTE": "1"]
        prepareSweep(app)
        app.launch()
        let playPause = app.buttons["player.playPause"]
        XCTAssertTrue(playPause.waitForExistence(timeout: 15))
        sleep(2)
        var issues = auditScreen(app, "kiku-player")
        // Down to the mini player (its chevron), then the tabs.
        app.buttons["player.close"].firstMatch.tap()
        XCTAssertTrue(sweepTab(app, "Settings").waitForExistence(timeout: 10), "the player closed to its mini player")
        sleep(2)
        issues += sweepTabsAndSettings(app, prefix: "kiku", tabs: ["Listen", "Marks", "Stats", "Settings"])
        keepSweepIssues(issues, "kiku-sweep-issues")
    }
}
