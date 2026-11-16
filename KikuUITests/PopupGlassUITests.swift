import XCTest

/// Screenshots of the lookup popup's glass (PopupGlassGallery): over a white page and over a
/// dark, busy picture, at 0, 25, 50 and 100 % opacity, in light and dark mode. Nothing is
/// checked but that the popup shows: the pictures are for looking at.
final class PopupGlassUITests: XCTestCase {
    func testPopupGlassScreenshots() {
        defer { XCUIDevice.shared.appearance = .light }
        for appearance in [XCUIDevice.Appearance.light, .dark] {
            XCUIDevice.shared.appearance = appearance
            for backdrop in ["white", "busy"] {
                for opacity in [0, 25, 50, 100] {
                    let app = XCUIApplication()
                    app.launchEnvironment = ["UITEST_KIKU": "1", "UITEST_POPUP_GLASS": backdrop, "UITEST_POPUP_OPACITY": String(opacity)]
                    app.launch()
                    let results = app.webViews.matching(identifier: "lookup.results").firstMatch
                    XCTAssertTrue(results.waitForExistence(timeout: 15), "the popup shows")
                    XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'to eat'")).firstMatch.waitForExistence(timeout: 10))
                    sleep(1)
                    let shot = XCTAttachment(screenshot: app.screenshot())
                    shot.name = "\(backdrop)-\(appearance == .dark ? "dark" : "light")-\(opacity)"
                    shot.lifetime = .keepAlways
                    add(shot)
                    app.terminate()
                }
            }
        }
    }
}
