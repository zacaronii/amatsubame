import XCTest

/// Settings rework: Watching's pages hold what moved there.
final class SettingsLayoutUITests: XCTestCase {
    private func open(_ app: XCUIApplication, _ row: String) {
        let element = app.descendants(matching: .any)[row].firstMatch
        for _ in 0..<8 where !(element.exists && element.isHittable) { app.swipeUp(velocity: .slow) }
        element.tap()
    }

    /// Japanese Audio Only is under Libraries, Download over Cellular under Playback, and the
    /// Downloads page is gone.
    func testWatchingHoldsWhatMoved() {
        let app = XCUIApplication()
        app.launchEnvironment["UITEST_MUTE"] = "1"
        app.launchEnvironment["UITEST_PLAYER"] = "1"
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.descendants(matching: .any)["watch.placeholder"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.descendants(matching: .any)["settings.downloads"].firstMatch.exists, "no Downloads row")

        open(app, "settings.libraries")
        XCTAssertTrue(app.navigationBars["Libraries"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Japanese Audio Only"].waitForExistence(timeout: 10), "Japanese Audio Only under Libraries")
        app.navigationBars.buttons.firstMatch.tap()

        open(app, "settings.playback")
        XCTAssertTrue(app.navigationBars["Playback"].waitForExistence(timeout: 10))
        let cellular = app.switches["downloads.cellular"]
        for _ in 0..<4 where !cellular.exists { app.swipeUp() }
        XCTAssertTrue(cellular.exists, "Download over Cellular under Playback")
        XCTAssertFalse(app.staticTexts["Japanese Audio Only"].exists, "not under Playback any more")
        app.navigationBars.buttons.firstMatch.tap()

        // Storage: "Downloaded", and saved subtitles with a Clear on their row.
        open(app, "settings.storage")
        let downloaded = app.descendants(matching: .any)["storage.downloads"].firstMatch
        XCTAssertTrue(downloaded.waitForExistence(timeout: 10))
        XCTAssertTrue(downloaded.label.contains("Downloaded"), downloaded.label)
        XCTAssertTrue(app.buttons["storage.clearSubtitles"].exists, "Clear on Saved Subtitles")
    }
}
