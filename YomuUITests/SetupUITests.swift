import XCTest

/// First-launch setup against a test account. Each test
/// gets its own app data (`UITEST_SETUP_DATA`), so setup runs as a real first launch. Needs
/// `TEST_KAVITA_*` (with `TEST_KAVITA_LIBRARIES`, see `TestAccounts.libraries`) and `KAVITA_URL`
/// in `.env`; skipped without them.
final class SetupUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func fresh() -> XCUIApplication {
        XCUIApplication.setup(data: "yomu-\(UUID().uuidString.prefix(8))")
    }

    func testSkippingAtWelcomeStaysSkipped() throws {
        let app = fresh()
        app.launch()
        XCTAssertTrue(app.buttons["setup.getStarted"].waitForExistence(timeout: 20), "setup shows on a first launch")
        app.buttons["setup.later"].tap()
        XCTAssertTrue(app.alerts["Set up later?"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.alerts.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Run Setup Again'")).firstMatch.exists)
        app.alerts.buttons["Skip"].tap()
        XCTAssertTrue(app.staticTexts["Connect Kavita"].waitForExistence(timeout: 10), "the library says what's missing")
        app.terminate()
        app.launch()
        XCTAssertFalse(app.buttons["setup.getStarted"].waitForExistence(timeout: 5), "skipped stays skipped")
    }

    func testWrongAddressOrKeyDoesntContinue() throws {
        let (url, key) = try { let v = try TestAccounts.require("KAVITA_URL", "TEST_KAVITA_KEY"); return (v[0], v[1]) }()
        let app = fresh()
        app.launch()
        app.buttons["setup.getStarted"].tap()
        XCTAssertTrue(app.waitForTitle("Connect Kavita"))
        app.type("https://kavita.invalid", into: "setup.server.url")
        app.type("not-a-key", into: "setup.server.key")
        app.buttons["setup.continue"].tap()
        let status = app.element("setup.server.status")
        XCTAssertTrue(status.waitForExistence(timeout: 30))
        XCTAssertEqual(app.buttons["setup.continue"].label, "Connect", "a wrong address doesn't connect")

        let field = app.element("setup.server.url")
        field.tap()
        field.press(forDuration: 1.2)
        if app.menuItems["Select All"].waitForExistence(timeout: 3) { app.menuItems["Select All"].tap() }
        field.typeText(XCUIKeyboardKey.delete.rawValue)
        field.typeText(url)
        app.buttons["setup.continue"].tap()
        let failed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != ''"), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [failed], timeout: 30), .completed)
        XCTAssertEqual(app.buttons["setup.continue"].label, "Connect", "a wrong key doesn't connect")
        _ = key
    }

    /// The bar with Continue covers what scrolls under it: on the dictionaries step the list
    /// showed through the footer's text and the button. Connects the demo Kavita
    /// (its config.json) to get there.
    func testButtonBarCoversTheList() throws {
        let v = try DemoServers.kavita()
        let app = fresh()
        app.launch()
        app.buttons["setup.getStarted"].tap()
        XCTAssertTrue(app.waitForTitle("Connect Kavita"))
        app.type(v[0], into: "setup.server.url")
        app.type(v[1], into: "setup.server.key")
        app.buttons["setup.continue"].tap()
        let connected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS 'found'"),
                                                  object: app.element("setup.server.status"))
        XCTAssertEqual(XCTWaiter.wait(for: [connected], timeout: 60), .completed)
        app.tapContinue()
        app.dismissSavePassword()
        XCTAssertTrue(app.waitForTitle("Which libraries are Japanese?"))
        app.tapContinue()
        XCTAssertTrue(app.waitForTitle("Get dictionaries"))
        sleep(2)
        // The first line under the button: the download size, else the Import link.
        let size = app.element("setup.dictionaries.size")
        let button = app.buttons["setup.continue"].frame
        let link = size.exists ? size.frame : app.element("setup.importDictionaries").frame
        XCTAssertLessThan(button.maxY, link.minY)
        let shot = app.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = "dictionaries-bar"
        attachment.lifetime = .keepAlways
        add(attachment)
        // Between the button and the link: the page's own background only, no list rows.
        guard let image = shot.image.cgImage, let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else {
            return XCTFail("no screenshot")
        }
        let scale = CGFloat(image.width) / app.windows.firstMatch.frame.width
        let y = Int(((button.maxY + link.minY) / 2) * scale), perPixel = image.bitsPerPixel / 8
        let first = bytes + y * image.bytesPerRow
        var odd = 0
        for x in stride(from: 0, to: image.width, by: 3) {
            let pixel = first + x * perPixel
            if (0..<3).contains(where: { abs(Int(pixel[$0]) - Int(first[$0])) > 12 }) { odd += 1 }
        }
        XCTAssertEqual(odd, 0, "the list shows through the bar under Continue")
    }

    /// The dictionaries step is a choice and nothing downloads by itself: skip (lookups then say
    /// how to get one), import your own, or download the recommended ones, which finish in the
    /// background while setup goes on. Connects the demo Kavita (its config.json).
    func testDictionariesAreAChoice() throws {
        let v = try DemoServers.kavita()
        func reachDictionaries() -> XCUIApplication {
            let app = fresh()
            app.launch()
            app.buttons["setup.getStarted"].tap()
            XCTAssertTrue(app.waitForTitle("Connect Kavita"))
            app.type(v[0], into: "setup.server.url")
            app.type(v[1], into: "setup.server.key")
            app.buttons["setup.continue"].tap()
            let connected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS 'found'"),
                                                      object: app.element("setup.server.status"))
            XCTAssertEqual(XCTWaiter.wait(for: [connected], timeout: 60), .completed)
            app.tapContinue()
            app.dismissSavePassword()
            XCTAssertTrue(app.waitForTitle("Which libraries are Japanese?"))
            app.tapContinue()
            XCTAssertTrue(app.waitForTitle("Get dictionaries"))
            return app
        }

        // Skip: nothing started, the page says lookups need one, and Done says none yet.
        var app = reachDictionaries()
        sleep(3)
        XCTAssertFalse(app.element("setup.dictionaries.progress").exists, "nothing downloads by itself")
        XCTAssertTrue(app.buttons["setup.continue"].label.hasPrefix("Download"), "the main button downloads the recommended ones")
        XCTAssertTrue(app.element("setup.dictionaries.size").label.contains("Wi-Fi"), "the size and a Wi-Fi hint")
        XCTAssertTrue(app.element("setup.dictionaries.later").exists, "says lookups need one, and where to add it later")
        app.buttons["setup.dictionaries.skip"].tap()
        XCTAssertTrue(app.waitForTitle("Connect Anki"))
        app.buttons["setup.anki.skip"].tap()
        XCTAssertTrue(app.waitForTitle("Extras"))
        app.tapContinue()
        XCTAssertTrue(app.element("setup.checklist.Dictionaries").label.contains("None yet"))
        app.buttons["setup.start"].tap()
        app.tabBars.buttons["Dictionary"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["search.addRecommended"].firstMatch.waitForExistence(timeout: 10),
                      "the Dictionary tab offers them")
        app.terminate()

        // Import My Own: the dictionaries page, with Import from Files.
        app = reachDictionaries()
        app.element("setup.importDictionaries").tap()
        XCTAssertTrue(app.navigationBars["Dictionaries"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Import from Files…"].exists || app.buttons["Import from Files…"].exists)
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.waitForTitle("Get dictionaries"))
        app.terminate()

        // Download: setup goes on at once while they download, and Done says they're coming.
        app = reachDictionaries()
        app.buttons["setup.continue"].tap()
        XCTAssertTrue(app.element("setup.dictionaries.progress").waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons["setup.continue"].label, "Continue")
        app.buttons["setup.continue"].tap()
        XCTAssertTrue(app.waitForTitle("Connect Anki"), "Continue isn't held up by the downloads")
        app.buttons["setup.anki.skip"].tap()
        XCTAssertTrue(app.waitForTitle("Extras"))
        app.tapContinue()
        let dictionaries = app.element("setup.checklist.Dictionaries")
        XCTAssertTrue(dictionaries.label.contains("Downloading") || dictionaries.label.contains("installed"), dictionaries.label)
        app.terminate()
    }

    /// Dictionaries from Hachidori (#40): the test host's address from `HACHIDORI_LINK_URL`, its
    /// dictionaries copied (after the recommended downloads that start on their own), then Done
    /// lists them. Several minutes: Hachidori's copies are a few hundred MB.
    func testUseHachidoriAtDictionaries() throws {
        let (url, key, hachidori) = try {
            let v = try TestAccounts.require("KAVITA_URL", "TEST_KAVITA_KEY", "HACHIDORI_LINK_URL")
            return (v[0], v[1], v[2])
        }()
        let app = fresh()
        app.launch()
        app.buttons["setup.getStarted"].tap()
        XCTAssertTrue(app.waitForTitle("Connect Kavita"))
        app.type(url, into: "setup.server.url")
        app.type(key, into: "setup.server.key")
        app.buttons["setup.continue"].tap()
        let connected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS 'libraries found'"),
                                                  object: app.element("setup.server.status"))
        XCTAssertEqual(XCTWaiter.wait(for: [connected], timeout: 30), .completed)
        app.tapContinue()
        XCTAssertTrue(app.waitForTitle("Which libraries are Japanese?"))
        app.tapContinue()

        XCTAssertTrue(app.waitForTitle("Get dictionaries"))
        app.type(hachidori, into: "setup.hachidori.address")
        app.buttons["setup.hachidori.copy"].tap()
        XCTAssertTrue(app.element("setup.hachidori.done").waitForExistence(timeout: 900), "copied from Hachidori")
        XCTAssertTrue(app.element("setup.hachidori.done").label.contains("Matches Hachidori"))
        app.tapContinue()
        XCTAssertTrue(app.waitForTitle("Connect Anki"))
    }

    /// Server, libraries (the guess), dictionaries (the recommended set, live), stopping at
    /// Anki and resuming there, no Anki, each extra, Done; then an update from Check Now.
    func testWholeSetupResumesAndUpdates() throws {
        let (url, key) = try { let v = try TestAccounts.require("KAVITA_URL", "TEST_KAVITA_KEY"); return (v[0], v[1]) }()
        let libraries = try TestAccounts.libraries("TEST_KAVITA_LIBRARIES")
        let app = fresh()
        app.launch()
        app.buttons["setup.getStarted"].tap()

        XCTAssertTrue(app.waitForTitle("Connect Kavita"))
        app.type(url, into: "setup.server.url")
        app.type(key, into: "setup.server.key")
        app.buttons["setup.continue"].tap()
        let connected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS 'libraries found'"),
                                                  object: app.element("setup.server.status"))
        XCTAssertEqual(XCTWaiter.wait(for: [connected], timeout: 30), .completed, "tested inline")
        app.tapContinue()

        XCTAssertTrue(app.waitForTitle("Which libraries are Japanese?"))
        let manga = app.switches["setup.library.\(libraries.japanese)"], books = app.switches["setup.library.\(libraries.english)"]
        XCTAssertTrue(manga.waitForExistence(timeout: 30))
        XCTAssertEqual(manga.value as? String, "1", "a Japanese name starts on")
        XCTAssertEqual(books.value as? String, "0", "an English one starts off")
        app.tapContinue()

        XCTAssertTrue(app.waitForTitle("Get dictionaries"), "no other app's setup to reuse; saw \(app.staticTexts["setup.title"].label)")
        XCTAssertEqual(app.element("recommended.jitendex").value as? String != nil, true)
        // The whole set, live: several minutes on a simulator. Waits here so Done can count them.
        app.buttons["setup.continue"].tap()
        let progress = app.element("setup.dictionaries.progress")
        XCTAssertTrue(progress.waitForExistence(timeout: 10))
        XCTAssertTrue(progress.waitForNonExistence(timeout: 900), "the downloads finish")
        app.tapContinue()

        XCTAssertTrue(app.waitForTitle("Connect Anki"))
        // Leave mid-way: setup comes back at the same step.
        app.terminate()
        app.launch()
        XCTAssertTrue(app.waitForTitle("Connect Anki"), "resumes where it was left")
        app.buttons["setup.anki.skip"].tap()

        XCTAssertTrue(app.waitForTitle("Extras"))
        for extra in ["Manga Text Recognition", "Read-Along", "kechimochi"] {
            app.element("setup.extra.\(extra)").tap()
            XCTAssertTrue(app.navigationBars.buttons.firstMatch.waitForExistence(timeout: 10), "\(extra) opens")
            app.navigationBars.buttons.firstMatch.tap()
            XCTAssertTrue(app.waitForTitle("Extras"), "and comes back")
        }
        app.tapContinue()

        XCTAssertTrue(app.staticTexts["setup.done"].waitForExistence(timeout: 10))
        let anki = app.element("setup.checklist.Anki")
        XCTAssertTrue(anki.label.contains("Later"), "Done says where the skipped step waits")
        XCTAssertTrue(app.element("setup.checklist.Dictionaries").label.contains("5 installed"))
        app.buttons["setup.start"].tap()
        XCTAssertFalse(app.buttons["setup.start"].waitForExistence(timeout: 3))

        // An update: Jitendex looks out of date; Check Now replaces it.
        app.terminate()
        app.launchEnvironment["UITEST_STALE_DICTIONARY"] = "jitendex"
        app.launch()
        app.tabBars.buttons["Settings"].tap()
        app.element("settings.dictionaries").tap()
        let checkNow = app.buttons["dictionaries.checkNow"]
        XCTAssertTrue(checkNow.waitForExistence(timeout: 10))
        checkNow.tap()
        let updated = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS 'Updated Jitendex'"), object: checkNow)
        XCTAssertEqual(XCTWaiter.wait(for: [updated], timeout: 600), .completed, "Check Now replaced it")

        // Run Setup Again: opens right away with Kavita connected; this time with Anki.
        guard let anki = TestAccounts.values["ANKI_URL"] else { return }
        app.navigationBars.buttons.firstMatch.tap()
        let advanced = app.element("settings.advanced")
        for _ in 0..<5 where !advanced.isHittable { app.swipeUp() }
        advanced.tap()
        app.buttons["advanced.runSetup"].tap()
        XCTAssertTrue(app.buttons["setup.getStarted"].waitForExistence(timeout: 10), "opens right away")
        app.buttons["setup.getStarted"].tap()
        XCTAssertTrue(app.waitForTitle("Connect Kavita"))
        XCTAssertEqual(app.buttons["setup.continue"].label, "Continue", "the server shows as connected")
        app.tapContinue()
        XCTAssertTrue(app.waitForTitle("Which libraries are Japanese?"))
        app.tapContinue()
        XCTAssertTrue(app.waitForTitle("Get dictionaries"))
        app.tapContinue()
        XCTAssertTrue(app.waitForTitle("Connect Anki"))
        app.type(anki, into: "setup.anki.url")
        if let key = TestAccounts.values["ANKI_KEY"], !key.isEmpty { app.type(key, into: "setup.anki.key") }
        app.buttons["setup.anki.test"].tap()
        app.tapContinue()
        XCTAssertTrue(app.waitForTitle("Where should cards go?"))
        XCTAssertTrue(app.element("setup.cards.review").waitForExistence(timeout: 20))
        app.tapContinue()
        XCTAssertTrue(app.waitForTitle("Extras"))
        app.tapContinue()
        XCTAssertTrue(app.staticTexts["setup.done"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.element("setup.checklist.Anki").label.contains("Later"))
        app.buttons["setup.start"].tap()
    }
}
