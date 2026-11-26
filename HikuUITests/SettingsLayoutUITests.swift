import XCTest

/// Hiku's Settings follow the other apps' groups: Lookup, Anki, Connections, then Advanced
/// (sharing the setup, cards waiting, logs; no Run Setup Again) and About.
final class SettingsLayoutUITests: XCTestCase {
    func testAdvancedHoldsTheSetupSharing() {
        let app = XCUIApplication()
        app.launch()
        let advanced = app.buttons["settings.advanced"].firstMatch
        for _ in 0..<6 where !(advanced.exists && advanced.isHittable) { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(advanced.waitForExistence(timeout: 10), "Advanced in Hiku's Settings")
        XCTAssertTrue(app.buttons["settings.about"].exists, "About beside it")
        advanced.tap()
        XCTAssertTrue(app.navigationBars["Advanced"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["advanced.waiting.ankiNote"].firstMatch.waitForExistence(timeout: 5),
                      "the extension's cards waiting to sync")
        XCTAssertFalse(app.buttons["advanced.runSetup"].exists, "Hiku has no first-launch setup to run again")
    }
}
