import XCTest

/// Try It with the Demo Servers (public beta).
final class DemoUITests: XCTestCase {
    func testDemoButtonWithoutTheDemo() {
        checkDemoButton(XCUIApplication.setup(data: "kiku-demo-\(UUID().uuidString.prefix(8))"), server: "Connect Audiobookshelf")
    }

    func testDemoSignsIn() throws {
        try checkDemoSignIn(XCUIApplication.setup(data: "kiku-demo-\(UUID().uuidString.prefix(8))"), server: "Connect Audiobookshelf")
    }

    /// Listen's search is a button at the top right, as in Yomu's Library and Miru's Watch, that
    /// opens Search with its field ready; a title finds the demo's audiobook.
    func testListenSearchButton() throws {
        let app = XCUIApplication.setup(data: "kiku-search-\(UUID().uuidString.prefix(8))")
        try checkDemoSignIn(app, server: "Connect Audiobookshelf")
        app.tapContinue()
        XCTAssertTrue(app.waitForTitle("Get dictionaries"))
        app.buttons["setup.dictionaries.skip"].tap()
        if app.waitForTitle("Connect Anki", timeout: 20) { app.buttons["setup.anki.skip"].tap() }
        if app.waitForTitle("Extras", timeout: 20) { app.tapContinue() }
        XCTAssertTrue(app.buttons["setup.start"].waitForExistence(timeout: 20))
        app.buttons["setup.start"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["listen.recentBook"].firstMatch.waitForExistence(timeout: 30), "Listen")
        XCTAssertFalse(app.searchFields.firstMatch.exists, "no search bar on Listen itself")
        let search = app.descendants(matching: .any)["listen.search"].firstMatch
        XCTAssertTrue(search.exists)
        search.tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("ごん")
        XCTAssertTrue(app.staticTexts["ごん狐"].firstMatch.waitForExistence(timeout: 5), "the audiobook found")
    }

    func testDemoInSettingsAndLeavingIt() throws {
        try checkDemoSettings(XCUIApplication.setup(data: "kiku-demoset-\(UUID().uuidString.prefix(8))"), server: "Connect Audiobookshelf", row: "settings.audiobookshelf")
    }
}
