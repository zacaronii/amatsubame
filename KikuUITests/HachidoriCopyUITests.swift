import XCTest

/// Settings ▸ Hachidori, then Settings ▸ Dictionaries ▸ Copy from Hachidori, against a real host
/// (in memory: nothing is kept; the host isn't changed). Needs
/// `TEST_RUNNER_UITEST_HACHIDORI_ADDRESS`; downloads every dictionary the host has.
final class HachidoriCopyUITests: XCTestCase {
    func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Scrolls down until `element` is on screen (lists make rows as they scroll into view).
    func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        _ = element.waitForExistence(timeout: 3)
        for _ in 0..<6 where !(element.exists && element.isHittable) { app.swipeUp() }
        for _ in 0..<12 where !(element.exists && element.isHittable) { app.swipeDown() }
    }

    func testCopiesTheHostsDictionaries() throws {
        guard let address = ProcessInfo.processInfo.environment["UITEST_HACHIDORI_ADDRESS"] else {
            throw XCTSkip("Set TEST_RUNNER_UITEST_HACHIDORI_ADDRESS.")
        }
        let app = XCUIApplication()
        app.launchEnvironment = ["UITEST_KIKU": "1"]
        app.launch()
        app.tabBars.buttons["Settings"].tap()

        // Settings ▸ Hachidori: on, with the host's address.
        let hachidoriRow = app.descendants(matching: .any)["settings.hachidori"].firstMatch
        reveal(hachidoriRow, in: app)
        XCTAssertTrue(hachidoriRow.waitForExistence(timeout: 10), "Settings ▸ Hachidori is on iOS too")
        hachidoriRow.tap()
        let enabled = app.switches["hachidori.enabled"].firstMatch
        XCTAssertTrue(enabled.waitForExistence(timeout: 5))
        enabled.switches.firstMatch.tap()
        let field = app.textFields["hachidori.address"].firstMatch
        field.tap()
        field.typeText(address)
        app.buttons["hachidori.link"].firstMatch.tap()
        let linked = app.descendants(matching: .any).matching(identifier: "hachidori.status")
            .matching(NSPredicate(format: "label CONTAINS 'Linked to'")).firstMatch
        XCTAssertTrue(linked.waitForExistence(timeout: 30), "linked to the host")
        shot(app, "hachidori linked")

        // Settings ▸ Dictionaries ▸ Copy from Hachidori.
        app.navigationBars.buttons["BackButton"].firstMatch.tap()
        let dictionariesRow = app.descendants(matching: .any)["settings.dictionaries"].firstMatch
        reveal(dictionariesRow, in: app)
        XCTAssertTrue(dictionariesRow.waitForExistence(timeout: 5))
        dictionariesRow.tap()
        let copyRow = app.descendants(matching: .any)["dictionaries.copyFromHachidori"].firstMatch
        reveal(copyRow, in: app)
        XCTAssertTrue(copyRow.waitForExistence(timeout: 5), "the Hachidori section shows while linked")
        copyRow.tap()
        let copy = app.buttons["hachidori.copy"].firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 30), "Hachidori's dictionaries are listed")
        shot(app, "before copying")
        copy.tap()
        let done = app.staticTexts["Matches Hachidori."].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 900), "every dictionary copied")
        shot(app, "after copying")
        XCTAssertTrue(app.buttons["Match Order and On/Off"].exists, "nothing left to download")

        // Back in Settings ▸ Dictionaries, the copies are installed.
        app.navigationBars.buttons.firstMatch.tap()
        let jitendex = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'dictionary.Jitendex'")).firstMatch
        XCTAssertTrue(jitendex.waitForExistence(timeout: 10), "Jitendex is installed")
        shot(app, "dictionaries")
    }
}
