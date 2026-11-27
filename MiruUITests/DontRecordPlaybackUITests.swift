import XCTest

/// Spike (never merged): Settings ▸ Test ▸ "Don't record playback" turns on, and is off again after
/// a relaunch.
final class DontRecordPlaybackUITests: XCTestCase {
    func testTheSwitchLastsUntilARelaunch() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["UITEST_PLAYER"] = "1"
        app.launchEnvironment["UITEST_MUTE"] = "1"
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        let toggle = openTheSwitch(app)
        XCTAssertEqual(toggle.value as? String, "0", "off at first")
        toggle.switches.firstMatch.tap()
        XCTAssertEqual(toggle.value as? String, "1")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "settings-dont-record"
        shot.lifetime = .keepAlways
        add(shot)

        app.terminate()
        app.launch()
        XCTAssertEqual(openTheSwitch(app).value as? String, "0", "off again after a relaunch")
    }

    private func openTheSwitch(_ app: XCUIApplication) -> XCUIElement {
        app.tabBars.buttons["Settings"].tap()
        let toggle = app.switches["settings.dontRecord"]
        for _ in 0..<8 where !toggle.isHittable { app.swipeUp() }
        XCTAssertTrue(toggle.isHittable, "Settings ▸ Test has the switch")
        return toggle
    }
}
