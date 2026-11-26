import XCTest

/// Settings rework: Lookup's pages hold what moved there.
final class SettingsLayoutUITests: XCTestCase {
    private func settings() -> XCUIApplication {
        let app = XCUIApplication.setup(data: "yomu-layout-\(UUID().uuidString.prefix(8))")
        app.launch()
        XCTAssertTrue(app.buttons["setup.later"].waitForExistence(timeout: 20))
        app.buttons["setup.later"].tap()
        XCTAssertTrue(app.alerts.buttons["Skip"].waitForExistence(timeout: 5))
        app.alerts.buttons["Skip"].tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForNonExistence(timeout: 5))
        sleep(1)
        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
        return app
    }

    private func open(_ app: XCUIApplication, _ row: String) {
        let element = app.descendants(matching: .any)[row].firstMatch
        for _ in 0..<8 where !(element.exists && element.isHittable) { app.swipeUp(velocity: .slow) }
        element.tap()
    }

    /// Word Marks (out of Anki): the switch and the known and ignored words; Show Lookup
    /// Timings is on Popup now, not in Advanced.
    func testLookupHoldsWordMarksAndTimings() {
        let app = settings()
        open(app, "settings.wordMarks")
        XCTAssertTrue(app.navigationBars["Word Marks"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.switches["lookup.marksWords"].exists, "Mark Words by Anki State")
        XCTAssertTrue(app.descendants(matching: .any)["wordMarks.knownWords"].firstMatch.exists, "Known and Ignored Words")
        app.navigationBars.buttons.firstMatch.tap()

        open(app, "settings.popup")
        XCTAssertTrue(app.navigationBars["Popup"].waitForExistence(timeout: 10))
        let timings = app.switches["advanced.lookupTimings"]
        for _ in 0..<6 where !timings.exists { app.swipeUp() }
        XCTAssertTrue(timings.exists, "Show Lookup Timings on Popup")
        app.navigationBars.buttons.firstMatch.tap()

        open(app, "settings.advanced")
        XCTAssertTrue(app.navigationBars["Advanced"].waitForExistence(timeout: 10))
        for _ in 0..<4 { app.swipeUp() }
        XCTAssertFalse(app.switches["advanced.lookupTimings"].exists, "not in Advanced any more")
    }

    /// Reading ▸ Download Rules: automatic downloads and reading downloaded pages' text ahead.
    func testReadingHasDownloadRules() {
        let app = settings()
        let rules = app.descendants(matching: .any)["settings.downloads"].firstMatch
        XCTAssertTrue(rules.waitForExistence(timeout: 10))
        XCTAssertTrue(rules.label.contains("Download Rules"), rules.label)
        rules.tap()
        XCTAssertTrue(app.navigationBars["Download Rules"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["downloads.automatic"].firstMatch.exists, "Automatic Downloads")
        XCTAssertTrue(app.switches["downloads.readText"].exists, "Read Text on Downloaded Pages")
    }

    /// Storage: "Downloaded", and a Clear on each kind (read-along audio, cache).
    func testStorageSaysDownloadedAndClears() {
        let app = settings()
        open(app, "settings.storage")
        let downloaded = app.descendants(matching: .any)["storage.downloads"].firstMatch
        XCTAssertTrue(downloaded.waitForExistence(timeout: 10))
        XCTAssertTrue(downloaded.label.contains("Downloaded"), downloaded.label)
        XCTAssertEqual(app.buttons["storage.removeReadAlongAudio"].label, "Clear")
        XCTAssertEqual(app.buttons["downloads.clearCache"].label, "Clear")
    }

    /// Advanced: Character Counts (from Storage), and no Sync Now (it's on the status card).
    func testAdvancedHoldsCharacterCounts() {
        let app = settings()
        open(app, "settings.advanced")
        XCTAssertTrue(app.descendants(matching: .any)["advanced.runSetup"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["advanced.characterCounts"].firstMatch.exists, "Character Counts in Advanced")
        XCTAssertFalse(app.buttons["advanced.syncNow"].exists, "Sync Now is on the status card only")
        app.navigationBars.buttons.firstMatch.tap()
        open(app, "settings.storage")
        XCTAssertTrue(app.descendants(matching: .any)["storage.downloads"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.descendants(matching: .any)["storage.characterCounts"].exists, "not in Storage any more")
    }
}
