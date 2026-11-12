import XCTest

/// Drives the reader against a Kavita server in the simulator. Needs
/// `UITEST_KAVITA_URL`, `UITEST_KAVITA_KEY`, `UITEST_LIBRARY` and `UITEST_SERIES` in the test runner's
/// environment (pass them to xcodebuild as `TEST_RUNNER_UITEST_*`); skipped otherwise.
/// The app runs in memory and never sends progress, so the server isn't changed.
final class ReaderUITests: XCTestCase {
    private var app: XCUIApplication!
    private var series = ""

    override func setUpWithError() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        guard let url = env["UITEST_KAVITA_URL"], let key = env["UITEST_KAVITA_KEY"] else {
            throw XCTSkip("Set TEST_RUNNER_UITEST_KAVITA_URL and TEST_RUNNER_UITEST_KAVITA_KEY to run reader UI tests.")
        }
        guard let series = env["UITEST_SERIES"], let library = env["UITEST_LIBRARY"] else {
            throw XCTSkip("Set TEST_RUNNER_UITEST_LIBRARY and TEST_RUNNER_UITEST_SERIES (a manga series in that library) to run reader UI tests.")
        }
        self.series = series
        self.library = library
        app = XCUIApplication()
        app.launchEnvironment["UITEST_KAVITA_URL"] = url
        app.launchEnvironment["UITEST_KAVITA_KEY"] = key
        if let delay = env["UITEST_DECODE_DELAY_MS"] { app.launchEnvironment["READER_DECODE_DELAY_MS"] = delay }
        XCUIDevice.shared.orientation = .portrait
    }

    private var library = ""

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
        super.tearDown()
    }

    func testReadPagesRightToLeft() throws {
        app.launch()
        openReader()
        let start = try pageCounter()
        snapshot("reader-start")

        // RTL: the next page is to the left, so swiping right moves forward.
        reader.swipeRight()
        XCTAssertEqual(try pageCounter(), start + 1, "swipe right should move forward")

        // Tapping the left third moves forward, the right third back.
        reader.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).tap()
        XCTAssertEqual(try pageCounter(), start + 2, "left tap zone should move forward")
        reader.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(try pageCounter(), start + 1, "right tap zone should move back")
        snapshot("reader-after-turns")
    }

    /// turning back and forth in many patterns must always end on a whole
    /// page. Debug builds report "aligned" or "part-way" in the reader's value. Brief part-way
    /// readings are counted (and recorded with the screen recording, see CLAUDE.md); one that
    /// lasts fails the test.
    func testTurningPatternsAlwaysLandOnAPage() throws {
        app.launch()
        openReader()
        reader.swipeRight()
        reader.swipeRight()
        let left = reader.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5))
        let right = reader.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
        var transient: [String] = []
        func check(_ step: String) {
            let value = reader.value as? String ?? ""
            if value.hasSuffix("part-way") { transient.append(step) }
            let aligned = expectation(for: NSPredicate { _, _ in (self.reader.value as? String ?? "").hasSuffix("aligned") },
                                      evaluatedWith: nil)
            let result = XCTWaiter().wait(for: [aligned], timeout: 1.5)
            XCTAssertEqual(result, .completed, "\(step): still part-way (\(self.reader.value as? String ?? ""))")
        }
        for i in 0..<5 { left.tap(); check("tap left \(i)") }
        for i in 0..<5 { right.tap(); check("tap right \(i)") }
        for i in 0..<4 { reader.swipeLeft(); check("swipe left \(i)"); reader.swipeRight(); check("swipe right \(i)") }
        for i in 0..<10 {
            if i.isMultiple(of: 2) { left.tap(); reader.swipeLeft(velocity: .fast) } else { right.tap(); reader.swipeRight(velocity: .fast) }
            check("tap then swipe back \(i)")
        }
        for i in 0..<3 { reader.swipeRight(velocity: .fast); reader.swipeRight(velocity: .fast); check("rapid swipes \(i)") }
        for i in 0..<4 { right.tap(); reader.swipeRight(velocity: .fast); check("tap then swipe same way \(i)") }
        reader.pinch(withScale: 2, velocity: 2)
        reader.pinch(withScale: 0.4, velocity: -2)
        reader.swipeLeft()
        check("pinch then swipe")
        let note = XCTAttachment(string: "brief part-way readings: \(transient.count)\n" + transient.joined(separator: "\n"))
        note.name = "page-turn-transients"
        note.lifetime = .keepAlways
        add(note)
        print("=== PAGE TURN TRANSIENTS \(transient.count): \(transient.joined(separator: ", "))")
    }

    /// A download running behind the reader redraws the series page under it; that once gave
    /// the open reader a new, never-loaded model (black screen with a spinner).
    func testReaderStaysOpenWhileADownloadRuns() throws {
        app.launch()
        let libraryRow = app.buttons[library].firstMatch
        XCTAssertTrue(libraryRow.waitForExistence(timeout: 20), "library \(library) not listed")
        // Libraries are shelves further down the Library home.
        for _ in 0..<6 where !libraryRow.isHittable { app.swipeUp() }
        libraryRow.tap()
        let tile = app.buttons["series.\(series)"].firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 20), "series \(series) not found")
        tile.tap()
        // Download buttons are on the volume rows (List), not the covers.
        let list = app.buttons["List"].firstMatch
        if list.waitForExistence(timeout: 20) { list.tap() }
        let download = app.buttons.matching(identifier: "download.button").matching(NSPredicate(format: "label == 'Download'")).firstMatch
        XCTAssertTrue(download.waitForExistence(timeout: 20), "no volume to download")
        download.tap()
        let open = app.buttons["series.continue"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 20))
        open.tap()
        XCTAssertTrue(reader.waitForExistence(timeout: 20), "reader didn't open")
        let start = try pageCounter()
        for step in 1...4 {
            sleep(3)
            XCTAssertTrue(reader.exists, "reader went back to loading after \(step * 3) s")
        }
        reader.swipeRight()
        XCTAssertEqual(try pageCounter(), start + 1)
    }

    func testPinchZoomDoesNotTurnThePage() throws {
        app.launch()
        openReader()
        let start = try pageCounter()

        reader.pinch(withScale: 2.5, velocity: 2)
        snapshot("reader-zoomed")
        // While zoomed, a drag pans the page instead of paging.
        reader.swipeRight()
        reader.pinch(withScale: 0.3, velocity: -2)
        XCTAssertEqual(try pageCounter(), start, "panning a zoomed page must not turn it")
    }

    func testSpreadsInLandscapeOnIPad() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("Spreads are an iPad/Mac feature.") }
        app.launch()
        openReader()
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(2)
        let start = try pageCounter()
        sleep(3)
        snapshot("ipad-spread")
        let screen = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screen.name = "ipad-spread-screen"
        screen.lifetime = .keepAlways
        add(screen)
        let layout = XCTAttachment(string: "window \(app.windows.firstMatch.frame)\nreader \(reader.frame)\nstart page \(start)")
        layout.name = "ipad-layout"
        layout.lifetime = .keepAlways
        add(layout)
        reader.swipeRight()
        let next = try pageCounter()
        XCTAssertEqual(app.windows.firstMatch.frame.width > app.windows.firstMatch.frame.height, true, "should be landscape")
        XCTAssertTrue(next - start == 2 || start == 1, "a spread turns two pages (start \(start), next \(next))")
    }

    /// Folding the iPhone Duo changes the page width (and spreads) under an open page: the
    /// screen went black and the next swipe jumped far back. Rotating does the same here.
    func testChangingSizeKeepsThePage() throws {
        app.launch()
        openReader()
        for _ in 0..<6 { reader.swipeRight() }
        let start = try pageCounter()
        for orientation in [UIDeviceOrientation.landscapeLeft, .portrait, .landscapeLeft, .portrait] {
            XCUIDevice.shared.orientation = orientation
            sleep(2)
            let page = try pageCounter()
            snapshot("size-\(orientation.rawValue)")
            XCTAssertTrue(abs(page - start) <= 1, "after rotating to \(orientation.rawValue): page \(page), was \(start)")
            XCTAssertTrue((reader.value as? String ?? "").hasSuffix("aligned"), "part-way after rotating: \(reader.value ?? "")")
        }
        reader.swipeRight()
        let next = try pageCounter()
        XCTAssertTrue(next > start && next - start <= 2, "a swipe after rotating went from \(start) to \(next)")
    }

    /// Needs Japanese manga (`UITEST_SERIES`/`UITEST_LIBRARY`), installed OCR models
    /// (`UITEST_OCR_MODELS`) and dictionaries (`UITEST_DICTIONARY_ZIPS`).
    func testTappingTextOnAPageOpensLookup() throws {
        try enableOCR()
        app.launch()
        openReader()
        let block = app.descendants(matching: .any).matching(identifier: "ocr.block").firstMatch
        // The current page is OCR'd in the background; the simulator runs the models on the CPU.
        XCTAssertTrue(block.waitForExistence(timeout: 90), "OCR found text on the page")
        let text = block.label
        block.tap()
        let popup = app.webViews.firstMatch
        XCTAssertTrue(popup.waitForExistence(timeout: 15), "lookup popup opened")
        XCTAssertTrue(popup.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'JPDB' OR label CONTAINS 'Jitendex'")).firstMatch
            .waitForExistence(timeout: 15), "dictionary results for \(text)")
        snapshot("ocr-lookup")
    }

    func testLongPressSelectsAnAreaWithoutTurningThePage() throws {
        try enableOCR()
        app.launch()
        openReader()
        let block = app.descendants(matching: .any).matching(identifier: "ocr.block").firstMatch
        XCTAssertTrue(block.waitForExistence(timeout: 90))
        let start = try pageCounter()

        // Long-press a corner of the page (outside text), then drag a box over the upper middle.
        // (OCR blocks inside the zoomable page report the page's frame to accessibility, so
        // the box is placed by page position rather than by a block's frame.)
        reader.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.97)).press(forDuration: 0.8)
        XCTAssertTrue(app.descendants(matching: .any)["reader.selectionOverlay"].waitForExistence(timeout: 5), "selection started")
        reader.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.12))
            .press(forDuration: 0.05, thenDragTo: reader.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)))
        XCTAssertFalse(app.descendants(matching: .any)["reader.selectionOverlay"].exists, "drawing the box ends selection")

        let popup = app.webViews.firstMatch
        let toast = app.staticTexts["reader.toast"]
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline, !popup.exists, !toast.exists { usleep(200_000) }
        XCTAssertFalse(toast.exists, "manual OCR said: \(toast.exists ? toast.label : "")")
        XCTAssertTrue(popup.exists, "the drawn box was read and looked up")
        snapshot("manual-box")
        app.swipeDown(velocity: .fast)
        XCTAssertEqual(try pageCounter(), start, "the long press must not turn the page")
    }

    /// Mines the tapped word. With `UITEST_ANKI_URL` and `UITEST_ANKI_DECK` (a scratch deck)
    /// the card is also sent; otherwise it stays queued in the in-memory outbox.
    func testMiningAWordFromAPage() throws {
        try enableOCR()
        let env = ProcessInfo.processInfo.environment
        if let anki = env["UITEST_ANKI_URL"], let deck = env["UITEST_ANKI_DECK"] {
            app.launchEnvironment["UITEST_ANKI_URL"] = anki
            app.launchEnvironment["UITEST_ANKI_DECK"] = deck
        }
        app.launch()
        openReader()
        let block = app.descendants(matching: .any).matching(identifier: "ocr.block").firstMatch
        XCTAssertTrue(block.waitForExistence(timeout: 90), "OCR found text on the page")
        block.tap()
        let add = app.webViews.buttons["Add to Anki"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 15), "the popup offers Add to Anki")
        add.tap()
        let toast = app.descendants(matching: .any)["lookup.minedToast"]
        XCTAssertTrue(toast.waitForExistence(timeout: 10), "mining confirms with a toast")
        XCTAssertTrue(toast.buttons["Undo"].exists)
        snapshot("mined")
        // Let the undo window pass so a configured scratch deck receives the card.
        sleep(UInt32(env["UITEST_ANKI_DECK"] == nil ? 0 : 12))
    }

    /// The phase 4 check: a card mined while AnkiConnect is unreachable waits in the queue
    /// and is sent once the server is reachable. Needs `UITEST_ANKI_URL` and a scratch
    /// `UITEST_ANKI_DECK`; the app starts with an unreachable AnkiConnect address.
    func testCardMinedOfflineIsSentAfterReconnecting() throws {
        try enableOCR()
        let env = ProcessInfo.processInfo.environment
        guard let anki = env["UITEST_ANKI_URL"], let deck = env["UITEST_ANKI_DECK"] else {
            throw XCTSkip("Needs UITEST_ANKI_URL and UITEST_ANKI_DECK (a scratch deck).")
        }
        app.launchEnvironment["UITEST_ANKI_URL"] = "http://127.0.0.1:9"
        app.launchEnvironment["UITEST_ANKI_DECK"] = deck
        app.launch()
        openReader()
        let block = app.descendants(matching: .any).matching(identifier: "ocr.block").firstMatch
        XCTAssertTrue(block.waitForExistence(timeout: 90), "OCR found text on the page")
        block.tap()
        let add = app.webViews.buttons["Add to Anki"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 15))
        add.tap()
        XCTAssertTrue(app.descendants(matching: .any)["lookup.minedToast"].waitForExistence(timeout: 10))
        sleep(8) // past the undo window: the first send fails

        // Close the popup and the reader, then look at the queue.
        app.swipeDown(velocity: .fast)
        XCTAssertTrue(app.webViews.firstMatch.waitForNonExistence(timeout: 5), "popup closed")
        // The black margin above the page toggles the controls (no text there).
        reader.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
        let close = app.buttons["reader.close"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 5), "reader controls")
        close.tap()
        app.tabBars.buttons["Settings"].tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Queue'")).firstMatch.tap()
        let card = app.descendants(matching: .any)["queue.card"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10), "the card is queued")
        XCTAssertTrue(card.label.contains("Waiting to retry"), "offline send failed and will retry: \(card.label)")
        snapshot("queued-offline")

        // Reconnect: enter the real address in Settings.
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'AnkiConnect'")).firstMatch.tap()
        let url = app.textFields.firstMatch
        XCTAssertTrue(url.waitForExistence(timeout: 5))
        url.tap()
        url.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 40) + anki)
        app.buttons["Test Connection"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'AnkiConnect v'")).firstMatch.waitForExistence(timeout: 20))
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["Sync Now"].firstMatch.tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Queue'")).firstMatch.tap()
        let sent = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == 'queue.card' AND label CONTAINS 'Sent'")).firstMatch
        XCTAssertTrue(sent.waitForExistence(timeout: 60), "the card reached Anki")
        snapshot("sent-after-reconnect")
    }

    // MARK: Helpers

    /// OCR tests get the models and dictionaries; paging tests run without them so
    /// taps never land on detected text.
    private func enableOCR() throws {
        let env = ProcessInfo.processInfo.environment
        guard let models = env["UITEST_OCR_MODELS"], let dictionaries = env["UITEST_DICTIONARY_ZIPS"] else {
            throw XCTSkip("Needs UITEST_OCR_MODELS and UITEST_DICTIONARY_ZIPS.")
        }
        app.launchEnvironment["UITEST_OCR_MODELS"] = models
        app.launchEnvironment["UITEST_DICTIONARY_ZIPS"] = dictionaries
    }

    /// The series page's volume rows: reading status on the left, download status on the right
    /// (a screenshot to check by eye, attached to the result).
    func testSeriesPageVolumeRows() throws {
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["home.today"].waitForExistence(timeout: 20), "Today row on the home")
        sleep(4)
        let home = XCTAttachment(screenshot: app.screenshot())
        home.name = "library-home"
        home.lifetime = .keepAlways
        add(home)
        let libraryRow = app.buttons[library].firstMatch
        XCTAssertTrue(libraryRow.waitForExistence(timeout: 20), "library \(library) not listed")
        // Libraries are shelves further down the Library home.
        for _ in 0..<6 where !libraryRow.isHittable { app.swipeUp() }
        libraryRow.tap()
        let tile = app.buttons["series.\(series)"].firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 20), "series \(series) not found")
        tile.tap()
        XCTAssertTrue(app.buttons["series.continue"].firstMatch.waitForExistence(timeout: 20))
        sleep(3)
        let grid = XCTAttachment(screenshot: app.screenshot())
        grid.name = "series-grid"
        grid.lifetime = .keepAlways
        add(grid)
        app.buttons["List"].firstMatch.tap()
        sleep(1)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "series-rows"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private var reader: XCUIElement { app.scrollViews["reader.paged"].firstMatch }

    private func openReader() {
        let libraryRow = app.buttons[library].firstMatch
        XCTAssertTrue(libraryRow.waitForExistence(timeout: 20), "library \(library) not listed")
        // Libraries are shelves further down the Library home.
        for _ in 0..<6 where !libraryRow.isHittable { app.swipeUp() }
        libraryRow.tap()
        let tile = app.buttons["series.\(series)"].firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 20), "series \(series) not found")
        tile.tap()
        let open = app.buttons["series.continue"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 20))
        open.tap()
        XCTAssertTrue(reader.waitForExistence(timeout: 20), "reader didn't open")
        sleep(2)
    }

    /// The page on screen, from the reader's accessibility value ("Page N of M").
    private func pageCounter() throws -> Int {
        sleep(1)
        let value = reader.value as? String ?? ""
        let number = value.split(separator: " ").dropFirst().first.flatMap { Int($0) }
        return try XCTUnwrap(number, "reader value: \(value)")
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
