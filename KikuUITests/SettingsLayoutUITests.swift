import XCTest

/// Settings rework: Listening's pages, with the watch's settings together on Apple Watch.
final class SettingsLayoutUITests: XCTestCase {
    private func open(_ app: XCUIApplication, _ row: String) {
        let element = app.descendants(matching: .any)[row].firstMatch
        for _ in 0..<8 where !(element.exists && element.isHittable) { app.swipeUp(velocity: .slow) }
        element.tap()
    }

    func testListeningHoldsTheWatchTogether() {
        let app = XCUIApplication()
        app.launchEnvironment["UITEST_KIKU"] = "1"
        app.launch()
        let settings = app.tabBars.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 20))
        settings.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
        let rules = app.descendants(matching: .any)["settings.downloads"].firstMatch
        XCTAssertTrue(rules.waitForExistence(timeout: 10))
        XCTAssertTrue(rules.label.contains("Download Rules"), rules.label)
        // (Libraries' "N of M" needs a server: the newcomer tour's demo Audiobookshelf shows it.)

        open(app, "settings.appleWatch")
        XCTAssertTrue(app.navigationBars["Apple Watch"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.switches["settings.watchLiveText"].exists, "Live Text on the Apple Watch page")
        // The test simulator has no watch: the page says so first.
        XCTAssertTrue(app.descendants(matching: .any)["appleWatch.notInstalled"].firstMatch.exists, "says Kiku isn't on the watch")
        app.navigationBars.buttons.firstMatch.tap()

        open(app, "settings.playback")
        XCTAssertTrue(app.navigationBars["Playback"].waitForExistence(timeout: 10))
        for _ in 0..<3 { app.swipeUp() }
        XCTAssertFalse(app.switches["settings.watchLiveText"].exists, "not under Playback any more")
        app.navigationBars.buttons.firstMatch.tap()

        // Storage ▸ Downloads says where the watch's items went.
        open(app, "settings.storage")
        let downloaded = app.descendants(matching: .any)["storage.downloads"].firstMatch
        XCTAssertTrue(downloaded.waitForExistence(timeout: 10))
        XCTAssertTrue(downloaded.label.contains("Downloaded"), downloaded.label)
        XCTAssertTrue(app.buttons["storage.clearTranscripts"].exists, "Clear on Saved Transcripts")
        open(app, "storage.downloads")
        XCTAssertTrue(app.descendants(matching: .any)["storage.watchPointer"].firstMatch.waitForExistence(timeout: 10),
                      "Storage points to Apple Watch")
    }

    /// The status card's chips open their connections, each its own; Hachidori has no Sync Now
    /// of its own (the card's is the general one).
    func testStatusChipsOpenTheirConnections() {
        let app = XCUIApplication()
        app.launchEnvironment["UITEST_KIKU"] = "1"
        app.launch()
        let settings = app.tabBars.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 20))
        settings.tap()
        for (chip, title) in [("status.Anki", "Anki"), ("status.kechimochi", "kechimochi"), ("status.Kaku", "Kaku")] {
            let element = app.descendants(matching: .any)[chip].firstMatch
            XCTAssertTrue(element.waitForExistence(timeout: 10), chip)
            element.tap()
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5), "\(chip) opens \(title)")
            app.navigationBars.buttons.firstMatch.tap()
            XCTAssertTrue(settings.waitForExistence(timeout: 5))
        }
        open(app, "settings.hachidori")
        XCTAssertTrue(app.navigationBars["Hachidori"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["hachidori.syncNow"].exists, "no Sync Now of its own")
    }
}
