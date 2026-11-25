import XCTest

/// What a newcomer sees (the public beta's scenarios): every tab and the Settings rows, each
/// with a screenshot kept in the result, and a word typed into Search.
extension XCTestCase {
    func keepScreenshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Opens each tab in turn (the tab bar, or the iPad's sidebar tabs) and keeps a screenshot
    /// of it, then the top level of each Settings row.
    func tourTabs(_ app: XCUIApplication, prefix: String) {
        let tabs = app.tabBars.buttons.allElementsBoundByIndex.map { $0.label }
        for tab in tabs {
            app.tabBars.buttons[tab].firstMatch.tap()
            sleep(3)
            keepScreenshot(app, "\(prefix)-tab-\(tab)")
        }
        guard tabs.contains("Settings") else { return }
        app.tabBars.buttons["Settings"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
        // The list is lazy: rows below the fold only exist once scrolled to.
        var rows: [String] = []
        for _ in 0..<8 {
            let seen = app.descendants(matching: .any).allElementsBoundByIndex.map { $0.identifier }
                .filter { $0.hasPrefix("settings.") && !rows.contains($0) }
            rows += Set(seen).sorted()
            app.swipeUp(velocity: .fast)
        }
        for row in rows {
            let element = app.descendants(matching: .any)[row].firstMatch
            for _ in 0..<8 where !(element.exists && element.isHittable) { app.swipeDown(velocity: .fast) }
            for _ in 0..<8 where !(element.exists && element.isHittable) { app.swipeUp(velocity: .slow) }
            guard element.exists, element.isHittable else { continue }
            element.tap()
            sleep(2)
            keepScreenshot(app, "\(prefix)-settings-\(row.dropFirst("settings.".count))")
            if app.navigationBars.buttons.firstMatch.exists { app.navigationBars.buttons.firstMatch.tap() }
            sleep(1)
        }
    }

    /// The Dictionary (or Search) tab with a word typed: results, or what it says without
    /// dictionaries.
    func searchDictionary(_ app: XCUIApplication, prefix: String, word: String = "食べる") {
        for name in ["Dictionary", "Search"] where app.tabBars.buttons[name].exists {
            app.tabBars.buttons[name].firstMatch.tap()
            let field = app.searchFields.firstMatch
            guard field.waitForExistence(timeout: 5) else { keepScreenshot(app, "\(prefix)-search-nofield"); return }
            field.tap()
            field.typeText(word + "\n")
            sleep(3)
            keepScreenshot(app, "\(prefix)-search")
            return
        }
    }
}

extension XCTestCase {
    /// A newcomer's setup with one server and nothing else: `server` is the title of its step
    /// ("Connect Kavita") and `fields` its fields by identifier. Takes the recommended
    /// dictionaries (setup needs one), skips Anki and the extras, and keeps a screenshot of
    /// each step.
    func setUpWithOneServer(_ app: XCUIApplication, prefix: String, server: String, fields: [(String, String)]) {
        XCTAssertTrue(app.buttons["setup.getStarted"].waitForExistence(timeout: 20), "setup shows on a first launch")
        keepScreenshot(app, "\(prefix)-1-welcome")
        app.buttons["setup.getStarted"].tap()
        XCTAssertTrue(app.waitForTitle(server))
        keepScreenshot(app, "\(prefix)-2-server-empty")
        for (identifier, value) in fields { app.type(value, into: identifier) }
        app.buttons["setup.continue"].tap()
        let connected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS 'found'"),
                                                  object: app.element("setup.server.status"))
        XCTAssertEqual(XCTWaiter.wait(for: [connected], timeout: 60), .completed, "\(server) connects")
        sleep(1)
        let status = app.element("setup.server.status"), button = app.buttons["setup.continue"]
        XCTAssertLessThanOrEqual(status.frame.maxY, button.frame.minY, "the result shows above Continue, not under it")
        keepScreenshot(app, "\(prefix)-3-server-connected")
        app.tapContinue()
        // Never Save: a saved password's AutoFill then gets in the way of the next app's fields.
        app.dismissSavePassword()
        if app.waitForTitle("Which libraries are Japanese?", timeout: 30) {
            sleep(3)
            keepScreenshot(app, "\(prefix)-4-libraries")
            app.tapContinue()
        }
        if app.waitForTitle("Get dictionaries", timeout: 20) {
            sleep(3)
            keepScreenshot(app, "\(prefix)-5-dictionaries")
            // The recommended set: it finishes in the background, so setup goes on at once.
            app.buttons["setup.continue"].tap()
            XCTAssertTrue(app.element("setup.dictionaries.progress").waitForExistence(timeout: 10))
            keepScreenshot(app, "\(prefix)-5b-dictionaries-downloading")
            app.tapContinue()
        }
        if app.waitForTitle("Connect Anki", timeout: 20) {
            keepScreenshot(app, "\(prefix)-6-anki")
            app.buttons["setup.anki.skip"].tap()
        }
        if app.waitForTitle("Extras", timeout: 20) {
            keepScreenshot(app, "\(prefix)-7-extras")
            app.tapContinue()
        }
        XCTAssertTrue(app.staticTexts["setup.done"].waitForExistence(timeout: 20), "setup finishes")
        keepScreenshot(app, "\(prefix)-8-done")
        app.buttons["setup.start"].tap()
        sleep(3)
    }

    /// A newcomer with no server: Set Up Later at the welcome.
    func skipSetup(_ app: XCUIApplication, prefix: String) {
        XCTAssertTrue(app.buttons["setup.getStarted"].waitForExistence(timeout: 20), "setup shows on a first launch")
        keepScreenshot(app, "\(prefix)-welcome")
        app.buttons["setup.later"].tap()
        XCTAssertTrue(app.alerts["Set up later?"].waitForExistence(timeout: 5))
        keepScreenshot(app, "\(prefix)-later-alert")
        app.alerts.buttons["Skip"].tap()
        sleep(3)
    }
}
