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

    /// Settings ▸ Tap to Turn Pages: the sides swapped, and off (swipes still turn).
    func testTapZonesSwappedAndOff() throws {
        app.launchEnvironment["UITEST_READER_TAPS"] = "inverted"
        app.launch()
        openReader()
        let start = try pageCounter()
        reader.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(try pageCounter(), start + 1, "swapped: the right side moves forward")
        reader.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).tap()
        XCTAssertEqual(try pageCounter(), start, "and the left side back")

        app.terminate()
        app.launchEnvironment["UITEST_READER_TAPS"] = "off"
        app.launch()
        openReader()
        let begin = try pageCounter()
        reader.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).tap()
        XCTAssertEqual(try pageCounter(), begin, "off: a tap doesn't turn the page")
        // (That tap showed the controls; another hides them.)
        reader.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        reader.swipeRight()
        XCTAssertEqual(try pageCounter(), begin + 1, "a swipe still does")
    }

    /// Double-Tap to Zoom: a double tap zooms (a swipe then pans, not pages), another zooms
    /// back out, and a single tap still turns the page.
    func testDoubleTapZoomsAndSingleTapStillTurns() throws {
        app.launchEnvironment["UITEST_READER_TAPS"] = "doubletap"
        app.launch()
        openReader()
        let start = try pageCounter()
        reader.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).doubleTap()
        sleep(1)
        snapshot("reader-double-tap-zoomed")
        reader.swipeRight()
        XCTAssertEqual(try pageCounter(), start, "zoomed in: the swipe pans the page")
        reader.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).doubleTap()
        sleep(1)
        reader.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).tap()
        XCTAssertEqual(try pageCounter(), start + 1, "zoomed out again: a single tap turns the page")
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

    /// A lookup leaves the page as it was: on the iPhone Duo's outer screen (a side safe area)
    /// the page shrank as the popup opened. Run it there, or on an iPhone in landscape.
    func testLookupKeepsThePageSize() throws {
        try enableOCR()
        app.launch()
        openReader()
        let block = app.descendants(matching: .any).matching(identifier: "ocr.block").firstMatch
        XCTAssertTrue(block.waitForExistence(timeout: 90), "OCR found text on the page")
        // Accessibility already has the new layout while the stale one is on screen, so this
        // looks at the screen: the right edge above the popup is page or black, and stays so.
        let before = rightEdgeIsBlack()
        snapshot("page-before-lookup")
        block.tap()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 15), "lookup popup opened")
        sleep(1)
        snapshot("page-with-popup")
        XCTAssertEqual(rightEdgeIsBlack(), before, "the page changed size with the popup open")
        app.closeLookup()
        sleep(1)
        XCTAssertEqual(rightEdgeIsBlack(), before, "the page changed size after the popup closed")
    }

    /// A lookup marks the word on the page's own lettering (nothing else is drawn over it).
    func testLookupMarksTheWordOnThePage() throws {
        try enableOCR()
        app.launch()
        openReader()
        let block = app.descendants(matching: .any).matching(identifier: "ocr.block").firstMatch
        XCTAssertTrue(block.waitForExistence(timeout: 90), "OCR found text on the page")
        let mark = app.descendants(matching: .any).matching(identifier: "ocr.highlight").firstMatch
        // Ordinary lettering gets a mark (a title drawn at angles has no exact places, and none):
        // screenshots to check by eye.
        var shots = 0
        for turn in 0..<14 where shots < 4 {
            let before = try pageCounter()
            reader.swipeRight()
            guard try pageCounter() != before else { continue }
            // Dialogue: a few blocks of several characters on the page.
            let japanese = app.descendants(matching: .any).matching(identifier: "ocr.block")
                .matching(NSPredicate(format: "label MATCHES %@", ".*[ぁ-んァ-ヶ一-龠]{6,}.*"))
            guard japanese.firstMatch.waitForExistence(timeout: 25) else { continue }
            // (The pages on either side are built too, and fill in as they're read: only this
            // page's blocks, taken at once, a different one each time.)
            let onScreen = japanese.allElementsBoundByIndex.filter { $0.exists && $0.isHittable }
            guard onScreen.count >= 2 else { continue }
            onScreen[turn % onScreen.count].tap()
            if mark.waitForExistence(timeout: 15) {
                shots += 1
                snapshot("ocr-mark-vertical-\(shots)")
            }
            app.closeLookup()
            sleep(1)
            XCTAssertFalse(mark.exists, "the mark goes with the popup")
        }
        XCTAssertGreaterThan(shots, 0, "a word was marked on the page")
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
        app.closeLookup()
        XCTAssertEqual(try pageCounter(), start, "the long press must not turn the page")
    }

    /// Mines the tapped word. With `UITEST_ANKI_URL` and `UITEST_ANKI_DECK` (a scratch deck; and
    /// `UITEST_ANKI_KEY` for a keyed AnkiConnect)
    /// the card is also sent; otherwise it stays queued in the in-memory outbox.
    func testMiningAWordFromAPage() throws {
        try enableOCR()
        let env = ProcessInfo.processInfo.environment
        if let anki = env["UITEST_ANKI_URL"], let deck = env["UITEST_ANKI_DECK"] {
            app.launchEnvironment["UITEST_ANKI_URL"] = anki
            app.launchEnvironment["UITEST_ANKI_DECK"] = deck
            if let key = env["UITEST_ANKI_KEY"] { app.launchEnvironment["UITEST_ANKI_KEY"] = key }
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
        // AnkiConnect's key (saved now, used once the real address is entered).
        if let key = env["UITEST_ANKI_KEY"] { app.launchEnvironment["UITEST_ANKI_KEY"] = key }
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
        app.closeLookup()
        XCTAssertTrue(app.webViews.firstMatch.waitForNonExistence(timeout: 5), "popup closed")
        // The black margin above the page toggles the controls (no text there).
        reader.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
        let close = app.buttons["reader.close"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 5), "reader controls")
        close.tap()
        // Settings ▸ Advanced ▸ Waiting to Sync ▸ Cards for Anki (the queue since the Settings rework).
        func openCardsWaiting() {
            app.tabBars.buttons["Settings"].tap()
            app.revealSettingsRow("settings.advanced").tap()
            let cards = app.descendants(matching: .any)["advanced.waiting.ankiNote"].firstMatch
            XCTAssertTrue(cards.waitForExistence(timeout: 10), "Advanced ▸ Cards for Anki")
            cards.tap()
        }
        func backToSettings() {
            for _ in 0..<3 where !app.navigationBars["Settings"].exists { app.buttons["BackButton"].firstMatch.tap(); sleep(1) }
        }
        openCardsWaiting()
        let card = app.descendants(matching: .any)["queue.card"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10), "the card is queued")
        XCTAssertTrue(card.label.contains("Waiting to retry"), "offline send failed and will retry: \(card.label)")
        snapshot("queued-offline")

        // Reconnect: the real address on Settings ▸ Anki.
        backToSettings()
        app.revealSettingsRow("settings.anki").tap()
        let url = app.textFields["anki.url"].firstMatch
        XCTAssertTrue(url.waitForExistence(timeout: 5))
        url.tap()
        url.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 40) + anki)
        app.buttons["anki.test"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'AnkiConnect v'")).firstMatch.waitForExistence(timeout: 20))
        backToSettings()
        // The status card's Sync Now, at the top of Settings.
        app.tabBars.buttons["Settings"].tap()
        let syncNow = app.buttons["Sync Now"].firstMatch
        for _ in 0..<4 where !(syncNow.exists && syncNow.isHittable) { app.swipeDown() }
        syncNow.tap()
        backToSettings()
        openCardsWaiting()
        let sent = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == 'queue.card' AND label CONTAINS 'Sent'")).firstMatch
        XCTAssertTrue(sent.waitForExistence(timeout: 60), "the card reached Anki")
        snapshot("sent-after-reconnect")
    }

    // MARK: Helpers

    /// OCR tests get the models and dictionaries; paging tests run without them so
    /// taps never land on detected text.
    /// Auto-scroll in the long strip: it moves on by itself at the chosen speed, waits while the
    /// controls show, carries on when they go, and closes from its capsule.
    func testAutoScrollInTheLongStrip() throws {
        app.launch()
        openReader()
        // The long strip, from the reader's settings.
        reader.tap()
        let settings = app.buttons["reader.settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        app.buttons["Long strip"].firstMatch.tap()
        app.buttons["Done"].firstMatch.tap()
        let strip = app.scrollViews["reader.strip"].firstMatch
        XCTAssertTrue(strip.waitForExistence(timeout: 10))
        func page() -> Int { Int((strip.value as? String ?? "").split(separator: " ").dropFirst().first ?? "") ?? -1 }
        let start = app.buttons["reader.autoScroll"].firstMatch
        if !start.exists { strip.tap() }
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.tap()
        let playPause = app.buttons["autoScroll.playPause"].firstMatch
        XCTAssertTrue(playPause.waitForExistence(timeout: 5))
        XCTAssertEqual(playPause.label, "Pause Auto-Scroll")
        // The fastest level, to see it move in a few seconds.
        for _ in 0..<5 { app.buttons["autoScroll.faster"].firstMatch.tap() }
        XCTAssertEqual(app.staticTexts["autoScroll.speed"].firstMatch.value as? String, "10 of 10")
        let before = page()
        let moved = expectation(for: NSPredicate { _, _ in page() > before }, evaluatedWith: nil)
        wait(for: [moved], timeout: 30)
        snapshot("auto-scroll-strip")

        // A tap brings up the controls, and it waits.
        strip.tap()
        XCTAssertTrue(app.buttons["reader.close"].waitForExistence(timeout: 5))
        let held = page()
        sleep(6)
        XCTAssertEqual(page(), held, "waits while the controls show")
        // They go: it carries on.
        strip.tap()
        let again = expectation(for: NSPredicate { _, _ in page() > held }, evaluatedWith: nil)
        wait(for: [again], timeout: 30)
        app.buttons["autoScroll.close"].firstMatch.tap()
        XCTAssertTrue(playPause.waitForNonExistence(timeout: 5))
    }

    /// The README's screenshots (`UITEST_CAPTURE=1`, `scripts/readme-screenshots.sh`): the Library
    /// with the demo server's books and manga, then Pepper&Carrot's page with dialogue, zoomed in on a
    /// bubble, with the popup open on 出来上がり.
    func testReadmeCapture() throws {
        guard ProcessInfo.processInfo.environment["UITEST_CAPTURE"] != nil else { throw XCTSkip("Set UITEST_CAPTURE=1 to record.") }
        try enableOCR()
        app.launch()
        XCTAssertTrue(app.buttons[library].firstMatch.waitForExistence(timeout: 30), "the Library")
        readmeScreenshot("readme-1-home", settle: 5)
        openReader()
        let dialogue = app.descendants(matching: .any).matching(identifier: "ocr.block")
            .matching(NSPredicate(format: "label MATCHES %@", ".*[ぁ-んァ-ヶ一-龠]{6,}.*"))
        for _ in 0..<12 {
            reader.swipeRight()
            if dialogue.firstMatch.waitForExistence(timeout: 30),
               dialogue.allElementsBoundByIndex.filter({ $0.exists && $0.isHittable }).count >= 2 { break }
        }
        sleep(2)
        // The bubble's second line ("…これで / 出来上がり" on the first such page): its first word,
        // after zooming in (a pinch, then down to the bubble) so it reads at phone width.
        func bubble() throws -> XCUIElement {
            let bubbles = dialogue.allElementsBoundByIndex.filter { $0.exists && $0.isHittable }
            return try XCTUnwrap(bubbles.first { $0.label.contains("出来上が") } ?? bubbles.first, "a bubble with dialogue")
        }
        reader.pinch(withScale: 2.5, velocity: 3)
        sleep(1)
        for _ in 0..<4 where (try? bubble())?.label.contains("出来上が") != true {
            reader.swipeDown(velocity: .slow); sleep(1)
        }
        sleep(1)
        // Pan the page up so its art starts under the status bar (no band of black above the
        // page or its white margin): the bubble, near the top of its panel, about 50 points down.
        let top = try bubble().frame.minY
        if top > 60 {
            let from = reader.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
            from.press(forDuration: 0.1, thenDragTo: from.withOffset(CGVector(dx: 0, dy: -(top - 50))),
                       withVelocity: .slow, thenHoldForDuration: 0.5)
            sleep(1)
        }
        try bubble().coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.75)).tap()
        let results = app.webViews.firstMatch.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Jitendex'")).firstMatch
        XCTAssertTrue(results.waitForExistence(timeout: 20), "dictionary results")
        readmeScreenshot("readme-2-lookup")
    }

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

    /// A page bookmark goes to the test account's Kavita (`UITEST_SENDS_MARKS`), shows in the
    /// series' list, opens the reader at its page from there, and is removed again: Kavita's
    /// bookmarks end as they began.
    func testPageBookmarkReachesKavitaAndOpensFromTheSeries() throws {
        let kavita = try KavitaTestAccount()
        let marksBefore = try kavita.snapshot()
        // Whatever happens, the test account ends as it began.
        addTeardownBlock { XCTAssertNil(try marksBefore.restore(), "the test account's bookmarks were put back") }
        let before = marksBefore.pageBookmarks.count
        app.launchEnvironment["UITEST_SENDS_MARKS"] = "1"
        app.launch()
        openReader()
        reader.swipeRight()
        reader.swipeRight()
        let page = try pageCounter()
        reader.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let bookmark = app.buttons["reader.bookmark"].firstMatch
        XCTAssertTrue(bookmark.waitForExistence(timeout: 10), "a bookmark button in the controls")
        bookmark.tap()
        XCTAssertEqual(bookmark.value as? String, "Bookmarked")
        XCTAssertTrue(waitForServer(before + 1), "the bookmark reached Kavita")
        snapshot("bookmark-in-reader")

        app.buttons["reader.close"].firstMatch.tap()
        let row = app.buttons["series.mark"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "the series lists it")
        for _ in 0..<8 where !row.isHittable { app.swipeUp() }
        XCTAssertTrue(row.label.contains("Page \(page)"), row.label)
        snapshot("bookmark-in-series")
        row.tap()
        XCTAssertTrue(reader.waitForExistence(timeout: 20))
        XCTAssertEqual(try pageCounter(), page, "opened at the bookmarked page")

        reader.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(bookmark.waitForExistence(timeout: 10))
        XCTAssertEqual(bookmark.value as? String, "Bookmarked")
        bookmark.tap()
        XCTAssertTrue(waitForServer(before), "removed from Kavita again (bookmarks: \((try? kavita.pageBookmarks().count) ?? -1), expected \(before))")
    }

    private func waitForServer(_ count: Int, timeout: TimeInterval = 45) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if (try? KavitaTestAccount().pageBookmarks().count) == count { return true }
            sleep(2)
        }
        return false
    }

    /// Add to Want to Read from the series page reaches the test account's Kavita and puts the
    /// series on the Library home's shelf; removing it takes it off both. The account ends as it
    /// began (`KavitaTestAccount` restores it either way).
    func testWantToReadReachesKavitaAndTheShelf() throws {
        let kavita = try KavitaTestAccount()
        let marksBefore = try kavita.snapshot()
        addTeardownBlock { XCTAssertNil(try marksBefore.restore(), "the test account's Want to Read was put back") }
        let seriesId = try kavita.seriesId(named: series)
        try XCTSkipIf(marksBefore.wantToRead.contains(seriesId), "the series is already in Want to Read")
        app.launchEnvironment["UITEST_SENDS_MARKS"] = "1"
        app.launch()

        let libraryRow = app.buttons[library].firstMatch
        XCTAssertTrue(libraryRow.waitForExistence(timeout: 20))
        for _ in 0..<6 where !libraryRow.isHittable { app.swipeUp() }
        libraryRow.tap()
        let tile = app.buttons["series.\(series)"].firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 20))
        tile.tap()
        let more = app.buttons["series.downloads"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 20))
        more.tap()
        let toggle = app.buttons["series.wantToRead"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "Want to Read in the series menu")
        XCTAssertEqual(toggle.label, "Add to Want to Read")
        toggle.tap()
        XCTAssertTrue(waitFor { (try? kavita.wantToRead())?.contains(seriesId) == true }, "it reached Kavita")

        // The Library home's shelf has it, and opens it.
        app.navigationBars.buttons.firstMatch.tap()
        app.navigationBars.buttons.firstMatch.tap()
        let shelf = app.descendants(matching: .any)["home.wantToRead"].firstMatch
        XCTAssertTrue(shelf.waitForExistence(timeout: 20), "a Want to Read shelf")
        snapshot("want-to-read-shelf")
        let onShelf = app.buttons["wantToRead.series.\(series)"].firstMatch
        XCTAssertTrue(onShelf.waitForExistence(timeout: 5))
        onShelf.tap()
        XCTAssertTrue(more.waitForExistence(timeout: 20))
        more.tap()
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.label, "Remove from Want to Read")
        toggle.tap()
        XCTAssertTrue(waitFor { (try? kavita.wantToRead())?.contains(seriesId) == false }, "removed from Kavita")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(shelf.waitForNonExistence(timeout: 10), "no shelf when it's empty")
    }

    /// A new collection made from the series page reaches the test account's Kavita (made empty,
    /// then filled), shows on the Library home and opens with the series; taking the series out
    /// (the last one, so confirmed) deletes it on Kavita. Teardown deletes any collection the test
    /// made and fails if one that was there changed.
    func testNewCollectionReachesKavitaAndGoesWithItsLastSeries() throws {
        let kavita = try KavitaTestAccount()
        let marksBefore = try kavita.snapshot()
        addTeardownBlock { XCTAssertNil(try marksBefore.restore(), "the test account's collections were put back") }
        let seriesId = try kavita.seriesId(named: series)
        let title = KavitaTestAccount.testCollectionTitle
        app.launchEnvironment["UITEST_SENDS_MARKS"] = "1"
        app.launch()

        let libraryRow = app.buttons[library].firstMatch
        XCTAssertTrue(libraryRow.waitForExistence(timeout: 20))
        for _ in 0..<6 where !libraryRow.isHittable { app.swipeUp() }
        libraryRow.tap()
        let tile = app.buttons["series.\(series)"].firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 20))
        tile.tap()
        openCollectionsSheet()
        app.buttons["collections.new"].firstMatch.tap()
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "asks for a title")
        field.typeText(title)
        app.alerts.buttons["Make"].firstMatch.tap()
        let row = app.buttons["collections.row.\(title)"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertEqual(row.value as? String, "In it")
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(waitFor { (try? kavita.collections())?.values.contains([seriesId]) == true }, "made on Kavita with the series in it")

        // The Library home lists it, and it opens with the series.
        app.navigationBars.buttons.firstMatch.tap()
        app.navigationBars.buttons.firstMatch.tap()
        app.swipeDown()
        let listed = app.buttons["collection.\(title)"].firstMatch
        if !listed.waitForExistence(timeout: 20) { snapshot("collections-missing") }
        XCTAssertTrue(listed.exists, "the Library home lists the collection")
        for _ in 0..<10 where !listed.isHittable { app.swipeUp() }
        listed.tap()
        XCTAssertTrue(app.buttons["collection.series.\(series)"].firstMatch.waitForExistence(timeout: 20), "the collection shows its series")
        app.buttons["collection.series.\(series)"].firstMatch.tap()

        // Out again: it's the last series, so it asks, and Kavita deletes the collection.
        openCollectionsSheet()
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        let confirm = app.buttons["Take Out and Delete \u{201C}\(title)\u{201D}"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "asks before taking out the last series")
        confirm.tap()
        XCTAssertTrue(row.waitForNonExistence(timeout: 5), "it leaves the sheet at once")
        XCTAssertTrue(waitFor { (try? kavita.collections())?.isEmpty == true }, "the collection is gone from Kavita")
        app.buttons["Done"].firstMatch.tap()
        app.navigationBars.buttons.firstMatch.tap()
        app.navigationBars.buttons.firstMatch.tap()
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertFalse(app.buttons["collection.\(title)"].firstMatch.waitForExistence(timeout: 5), "and from the Library home")
    }

    /// A reading list made from a volume's menu reaches the test account's Kavita, gets a second
    /// volume, opens from the Library home, is reordered (Kavita follows), emptied (the list stays,
    /// as on Kavita) and deleted. No reading progress changes. Teardown deletes any list the test
    /// made and fails if one that was there changed.
    func testReadingListReachesKavitaAndIsReorderedAndDeleted() throws {
        let kavita = try KavitaTestAccount()
        let marksBefore = try kavita.snapshot()
        addTeardownBlock { XCTAssertNil(try marksBefore.restore(), "the test account's reading lists were put back") }
        let title = KavitaTestAccount.testCollectionTitle
        app.launchEnvironment["UITEST_SENDS_MARKS"] = "1"
        app.launch()

        let libraryRow = app.buttons[library].firstMatch
        XCTAssertTrue(libraryRow.waitForExistence(timeout: 20))
        for _ in 0..<6 where !libraryRow.isHittable { app.swipeUp() }
        libraryRow.tap()
        let tile = app.buttons["series.\(series)"].firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 20))
        tile.tap()
        let tiles = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'volume.'"))
        let first = tiles.element(boundBy: 0), second = tiles.element(boundBy: 1)
        XCTAssertTrue(first.waitForExistence(timeout: 20))
        let chapters = try kavita.chapters(series: series)
        let progressBefore = try chapters.map { try kavita.progress(chapterId: $0) }
        // The list this test made (not one the account already had).
        func items() -> [Int]? { (try? kavita.readingLists())?.first { marksBefore.readingLists[$0.key] == nil }?.value }

        // 1. A new list with the first volume.
        first.press(forDuration: 1.2)
        app.buttons["chapter.addToReadingList"].firstMatch.tap()
        app.buttons["readingLists.new"].firstMatch.tap()
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText(title)
        app.alerts.buttons["Make"].firstMatch.tap()
        XCTAssertTrue(waitFor { items()?.count == 1 }, "made on Kavita with one volume")

        // 2. The second volume into it, after the first.
        second.press(forDuration: 1.2)
        app.buttons["chapter.addToReadingList"].firstMatch.tap()
        let row = app.buttons["readingLists.row.\(title)"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(waitFor { items()?.count == 2 }, "the second volume added")
        let added = try XCTUnwrap(items())

        // 3. From the Library home: an item opens; the second dragged first, and Kavita follows.
        app.navigationBars.buttons.firstMatch.tap()
        app.navigationBars.buttons.firstMatch.tap()
        app.swipeDown()
        let listed = app.buttons["readingList.\(title)"].firstMatch
        XCTAssertTrue(listed.waitForExistence(timeout: 20))
        for _ in 0..<10 where !listed.isHittable { app.swipeUp() }
        listed.tap()
        XCTAssertTrue(app.buttons["readingList.item.\(added[1])"].firstMatch.waitForExistence(timeout: 20))
        // An item opens the reader (progress is held in UI tests and checked below).
        app.buttons["readingList.item.\(added[0])"].firstMatch.tap()
        XCTAssertTrue(reader.waitForExistence(timeout: 20), "the reader opened from the list")
        reader.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
        let close = app.buttons["reader.close"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 5), "reader controls")
        close.tap()
        XCTAssertTrue(app.buttons["readingList.edit"].firstMatch.waitForExistence(timeout: 10))
        app.buttons["readingList.edit"].firstMatch.tap()
        let handles = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Reorder'"))
        XCTAssertTrue(handles.element(boundBy: 1).waitForExistence(timeout: 5), "reorder handles")
        handles.element(boundBy: 1).press(forDuration: 0.6, thenDragTo: handles.element(boundBy: 0))
        XCTAssertTrue(waitFor { items() == [added[1], added[0]] }, "Kavita's order follows")

        // (Step 4, Next in List, comes with the next part.)
        // 5. Both taken out (the last one says the list stays): Kavita keeps the list, empty.
        app.buttons["readingList.edit"].firstMatch.tap()
        for chapter in [added[1], added[0]] {
            let item = app.buttons["readingList.item.\(chapter)"].firstMatch
            XCTAssertTrue(item.waitForExistence(timeout: 10))
            item.swipeLeft()
            let delete = app.buttons["Delete"].firstMatch
            XCTAssertTrue(delete.waitForExistence(timeout: 5), "swipe to take out")
            delete.tap()
            if app.alerts.buttons["Take Out"].waitForExistence(timeout: 3) { app.alerts.buttons["Take Out"].tap() }
            XCTAssertTrue(item.waitForNonExistence(timeout: 5))
        }
        XCTAssertTrue(waitFor { items() == [] }, "emptied on Kavita, the list kept")

        // 6. Deleted.
        app.buttons["readingList.more"].firstMatch.tap()
        app.buttons["readingList.delete"].firstMatch.tap()
        app.buttons["Delete Reading List"].firstMatch.tap()
        XCTAssertTrue(waitFor { (try? kavita.readingLists()).map { Set($0.keys) == Set(marksBefore.readingLists.keys) } == true }, "deleted on Kavita")
        XCTAssertEqual(try chapters.map { try kavita.progress(chapterId: $0) }, progressBefore, "no reading progress changed")
    }

    /// Reading in a list: a manga volume's end offers the list's next, a book in another
    /// library, and swiping on past the end goes nowhere else; tapping it swaps to the book's
    /// reader with the list kept. The list is made through the app; teardown deletes it and fails
    /// if anything else on the account changed. No reading progress changes.
    func testTheEndOfAVolumeOffersTheListsNextAcrossFormats() throws {
        let env = ProcessInfo.processInfo.environment
        guard let bookLibrary = env["UITEST_BOOK_LIBRARY"], let bookSeries = env["UITEST_BOOK_SERIES"] else {
            throw XCTSkip("Set TEST_RUNNER_UITEST_BOOK_LIBRARY and TEST_RUNNER_UITEST_BOOK_SERIES for the book in the list.")
        }
        let kavita = try KavitaTestAccount()
        let marksBefore = try kavita.snapshot()
        addTeardownBlock { XCTAssertNil(try marksBefore.restore(), "the test account's reading lists were put back") }
        let title = KavitaTestAccount.testCollectionTitle
        let chapters = try kavita.chapters(series: series)
        let progressBefore = try chapters.map { try kavita.progress(chapterId: $0) }
        func items() -> [Int]? { (try? kavita.readingLists())?.first { marksBefore.readingLists[$0.key] == nil }?.value }
        app.launchEnvironment["UITEST_SENDS_MARKS"] = "1"
        app.launchEnvironment["UITEST_READER_OPENS_AT_END"] = "1"
        app.launch()

        // The list: the manga's first volume, then the book's first volume.
        addFirstVolume(library: library, series: series, new: true)
        XCTAssertTrue(waitFor { items()?.count == 1 }, "made on Kavita")
        addFirstVolume(library: bookLibrary, series: bookSeries, new: false)
        XCTAssertTrue(waitFor { items()?.count == 2 }, "the book added after it")
        let listed = try XCTUnwrap(items())

        // From the list, the manga volume; to its last page, then onto the end page.
        app.swipeDown()
        let list = app.buttons["readingList.\(title)"].firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 20))
        for _ in 0..<10 where !list.isHittable { app.swipeUp() }
        list.tap()
        let first = app.buttons["readingList.item.\(listed[0])"].firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 20))
        first.tap()
        XCTAssertTrue(reader.waitForExistence(timeout: 30), "the manga reader opened from the list")
        let value = (reader.value as? String ?? "").split(separator: " ").compactMap { Int($0.trimmingCharacters(in: .punctuationCharacters)) }
        XCTAssertTrue(value.count == 2 && value[0] == value[1], "opened on the last page: \(reader.value ?? "")")
        // The end page sits beside the last one (in the hierarchy before it's on screen).
        let next = app.buttons["reader.next"].firstMatch
        let screen = app.windows.firstMatch.frame
        func onScreen() -> Bool { next.exists && screen.contains(CGPoint(x: next.frame.midX, y: next.frame.midY)) }
        for _ in 0..<3 where !onScreen() { reader.swipeRight(); sleep(1) }   // forward in right-to-left
        XCTAssertTrue(onScreen(), "the end page")
        XCTAssertTrue(next.label.contains("\u{201C}\(title)\u{201D}"), "offers the list's next: \(next.label)")
        // Swiping on past the end doesn't open anything (only the button does).
        reader.swipeRight()
        sleep(2)
        XCTAssertTrue(onScreen() && reader.exists, "still the manga reader's end page")

        // The book's reader replaces it, in the list.
        next.tap()
        XCTAssertTrue(app.descendants(matching: .any)["book.page"].firstMatch.waitForExistence(timeout: 60), "the book opened from the offer")
        XCTAssertFalse(reader.exists)
        XCTAssertEqual(try chapters.map { try kavita.progress(chapterId: $0) }, progressBefore, "no reading progress changed")
    }

    /// The other way: a book's end offers the list's next, a manga volume, and tapping it swaps
    /// the book's reader for the manga reader.
    func testTheEndOfABookOffersTheListsNextManga() throws {
        let env = ProcessInfo.processInfo.environment
        guard let bookLibrary = env["UITEST_BOOK_LIBRARY"], let bookSeries = env["UITEST_BOOK_SERIES"] else {
            throw XCTSkip("Set TEST_RUNNER_UITEST_BOOK_LIBRARY and TEST_RUNNER_UITEST_BOOK_SERIES for the book in the list.")
        }
        let kavita = try KavitaTestAccount()
        let marksBefore = try kavita.snapshot()
        addTeardownBlock { XCTAssertNil(try marksBefore.restore(), "the test account's reading lists were put back") }
        let title = KavitaTestAccount.testCollectionTitle
        let chapters = try kavita.chapters(series: series)
        let progressBefore = try chapters.map { try kavita.progress(chapterId: $0) }
        func items() -> [Int]? { (try? kavita.readingLists())?.first { marksBefore.readingLists[$0.key] == nil }?.value }
        app.launchEnvironment["UITEST_SENDS_MARKS"] = "1"
        app.launchEnvironment["UITEST_READER_OPENS_AT_END"] = "1"
        app.launch()

        addFirstVolume(library: bookLibrary, series: bookSeries, new: true)
        XCTAssertTrue(waitFor { items()?.count == 1 }, "made on Kavita with the book")
        addFirstVolume(library: library, series: series, new: false)
        XCTAssertTrue(waitFor { items()?.count == 2 }, "the manga added after it")
        let listed = try XCTUnwrap(items())

        let list = app.buttons["readingList.\(title)"].firstMatch
        for _ in 0..<10 where !list.isHittable { app.swipeUp() }
        list.tap()
        let first = app.buttons["readingList.item.\(listed[0])"].firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 20))
        first.tap()
        let page = app.descendants(matching: .any)["book.page"].firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 60), "the book opened from the list")
        sleep(3)
        // On through its last section to the end (forward is a swipe right in a vertical book).
        let next = app.buttons["reader.next"].firstMatch
        for _ in 0..<40 where !next.exists { page.swipeRight(); sleep(1) }
        XCTAssertTrue(next.waitForExistence(timeout: 5), "the end of the book")
        XCTAssertTrue(next.label.contains("\u{201C}\(title)\u{201D}"), "offers the list's next: \(next.label)")
        next.tap()
        XCTAssertTrue(reader.waitForExistence(timeout: 30), "the manga reader replaced the book")
        XCTAssertFalse(page.exists)
        XCTAssertEqual(try chapters.map { try kavita.progress(chapterId: $0) }, progressBefore, "no reading progress changed")
    }

    /// Mark as Read on a volume and Mark Series as Read / Unread reach the test account's Kavita
    /// through its mark endpoints, and add nothing to its reading history. Runs only on a series
    /// with nothing read; teardown marks unread whatever it marked and checks the pages read.
    func testMarkingReadReachesKavitaAndIsNotReading() throws {
        let kavita = try KavitaTestAccount()
        let seriesId = try kavita.seriesId(named: series)
        let before = try kavita.pagesRead(seriesId: seriesId)
        guard before.values.allSatisfy({ $0.read == 0 }) else { throw XCTSkip("Needs a series with nothing read on the test account.") }
        let marksBefore = try kavita.snapshot(progressOf: seriesId)
        addTeardownBlock { XCTAssertNil(try marksBefore.restore(), "the test account's progress was put back") }
        let historyBefore = try kavita.readingHistoryCount(seriesId: seriesId)
        func read() -> [Int: (read: Int, pages: Int)] { (try? kavita.pagesRead(seriesId: seriesId)) ?? [:] }
        app.launchEnvironment["UITEST_SENDS_MARKS"] = "1"
        app.launch()

        let libraryRow = app.buttons[library].firstMatch
        XCTAssertTrue(libraryRow.waitForExistence(timeout: 20))
        for _ in 0..<6 where !libraryRow.isHittable { app.swipeUp() }
        libraryRow.tap()
        let tile = app.buttons["series.\(series)"].firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 20))
        tile.tap()
        let volume = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'volume.'")).element(boundBy: 0)
        XCTAssertTrue(volume.waitForExistence(timeout: 20))

        // A volume.
        volume.press(forDuration: 1.2)
        app.buttons["Mark as Read"].firstMatch.tap()
        XCTAssertTrue(waitFor { read().values.filter { $0.read == $0.pages }.count == 1 }, "one volume read on Kavita")

        // The whole series, asked first.
        let more = app.buttons["series.downloads"].firstMatch
        more.tap()
        app.buttons["series.markRead"].firstMatch.tap()
        let confirm = app.buttons["series.markConfirm"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "asked first")
        confirm.tap()
        XCTAssertTrue(waitFor { read().values.allSatisfy { $0.read == $0.pages } }, "every volume read on Kavita")
        more.tap()
        app.buttons["series.markUnread"].firstMatch.tap()
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(waitFor { read().values.allSatisfy { $0.read == 0 } }, "every volume unread on Kavita")
        sleep(5)   // Kavita records reading sessions in a background job
        XCTAssertEqual(try kavita.readingHistoryCount(seriesId: seriesId), historyBefore, "not recorded as reading")
    }

    /// A list's screen shows what's read by the series page's rule: marked read on the series
    /// page, the item shows read at once and after the list is read again from Kavita; marked
    /// unread, it doesn't. Teardown deletes the list and marks unread what it marked.
    func testAListShowsWhatsRead() throws {
        let kavita = try KavitaTestAccount()
        let seriesId = try kavita.seriesId(named: series)
        guard try kavita.pagesRead(seriesId: seriesId).values.allSatisfy({ $0.read == 0 }) else {
            throw XCTSkip("Needs a series with nothing read on the test account.")
        }
        let marksBefore = try kavita.snapshot(progressOf: seriesId)
        addTeardownBlock { XCTAssertNil(try marksBefore.restore(), "the test account was put back") }
        let title = KavitaTestAccount.testCollectionTitle
        func items() -> [Int]? { (try? kavita.readingLists())?.first { marksBefore.readingLists[$0.key] == nil }?.value }
        app.launchEnvironment["UITEST_SENDS_MARKS"] = "1"
        app.launch()

        addFirstVolume(library: library, series: series, new: true)
        XCTAssertTrue(waitFor { items()?.count == 1 }, "made on Kavita")
        let chapter = try XCTUnwrap(items()?.first)

        func setRead(_ read: Bool) {
            let libraryRow = app.buttons[library].firstMatch
            for _ in 0..<10 where !libraryRow.isHittable { app.swipeUp() }
            libraryRow.tap()
            let tile = app.buttons["series.\(series)"].firstMatch
            XCTAssertTrue(tile.waitForExistence(timeout: 20))
            tile.tap()
            let volume = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'volume.'")).element(boundBy: 0)
            XCTAssertTrue(volume.waitForExistence(timeout: 20))
            volume.press(forDuration: 1.2)
            app.buttons[read ? "Mark as Read" : "Mark as Unread"].firstMatch.tap()
            app.tabBars.buttons["Library"].tap()
            app.tabBars.buttons["Library"].tap()
            app.swipeDown()
        }
        func listValue() -> String? {
            let list = app.buttons["readingList.\(title)"].firstMatch
            for _ in 0..<10 where !list.isHittable { app.swipeUp() }
            list.tap()
            let item = app.buttons["readingList.item.\(chapter)"].firstMatch
            XCTAssertTrue(item.waitForExistence(timeout: 20))
            return item.value as? String
        }

        setRead(true)
        XCTAssertEqual(listValue(), "Read", "at once, from this device's progress")
        XCTAssertTrue(waitFor { (try? kavita.pagesRead(seriesId: seriesId)[chapter]).map { $0.read == $0.pages } == true }, "read on Kavita")
        // Read again from Kavita (back and in again): still read.
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertEqual(listValue(), "Read", "after the list is read again")
        app.navigationBars.buttons.firstMatch.tap()
        setRead(false)
        XCTAssertEqual(listValue(), "", "unread at once")
        XCTAssertTrue(waitFor { (try? kavita.pagesRead(seriesId: seriesId)[chapter])?.read == 0 }, "unread on Kavita")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertEqual(listValue(), "", "and after the list is read again")
    }

    /// Settings ▸ Storage lists read-along audio (none on this simulator), with Remove asked
    /// first and off while there's nothing to remove. Reads nothing from Audiobookshelf.
    func testStorageListsReadAlongAudio() throws {
        app.launch()
        app.tabBars.buttons["Settings"].tap()
        let storage = app.buttons["settings.storage"].firstMatch
        for _ in 0..<8 where !storage.isHittable { app.swipeUp() }
        storage.tap()
        let remove = app.buttons["storage.removeReadAlongAudio"].firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 10), "the read-along audio row")
        XCTAssertTrue(app.staticTexts["Read-Along Audio"].exists)
        XCTAssertFalse(remove.isEnabled, "nothing to remove")
        snapshot("storage-read-along")
    }

    /// #166 in Yomu: two screens deep in Settings, tapping the Settings tab again shows its top.
    @MainActor
    func testSettingsTabReturnsToTheTopFromTwoScreensDeep() throws {
        app.launch()
        checkSettingsTabRetap(app)
    }

    /// The Library's stack is driven by a path of its own: two screens deep (a library ▸ a
    /// series), tapping Library again shows its top, and the next tap opens the library.
    @MainActor
    func testLibraryTabReturnsToTheTopFromTwoScreensDeep() throws {
        app.launch()
        let tab = app.tabBars.buttons["Library"]
        let libraryRow = app.buttons[library].firstMatch
        XCTAssertTrue(libraryRow.waitForExistence(timeout: 20))
        for _ in 0..<6 where !libraryRow.isHittable { app.swipeUp() }
        libraryRow.tap()
        let tile = app.buttons["series.\(series)"].firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 20))
        tile.tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'volume.'")).firstMatch.waitForExistence(timeout: 20),
                      "the series, two screens deep")
        sleep(1)
        tab.tap()
        for _ in 0..<6 where !(libraryRow.exists && libraryRow.isHittable) { app.swipeUp() }
        XCTAssertTrue(libraryRow.exists && libraryRow.isHittable, "the top of Library")
        libraryRow.tap()
        XCTAssertTrue(tile.waitForExistence(timeout: 20), "the next tap opens the library")
    }

    /// Split Wide Pages, in portrait: page 2 marked wide (`UITEST_WIDE_PAGES`; the test account has
    /// no wide page) is shown as its right half, then its left (a right-to-left book); going back
    /// lands on the far half; switched off, it's one page again. Progress stays on the simulator.
    func testAWidePageIsShownOneHalfAtATime() throws {
        app.launchEnvironment["UITEST_WIDE_PAGES"] = "1"
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        openReader()
        func value() -> String { reader.value as? String ?? "" }
        let start = try pageCounter()
        XCTAssertEqual(start, 1, "opens at the first page")
        reader.swipeRight()   // forward in right to left
        sleep(1)
        XCTAssertTrue(value().hasPrefix("Page 2 of") && value().contains("right half"), value())
        reader.swipeRight()
        sleep(1)
        XCTAssertTrue(value().hasPrefix("Page 2 of") && value().contains("left half"), value())
        snapshot("split-second-half")
        reader.swipeRight()
        sleep(1)
        XCTAssertTrue(value().hasPrefix("Page 3 of") && !value().contains("half"), value())
        reader.swipeLeft()
        sleep(1)
        XCTAssertTrue(value().hasPrefix("Page 2 of") && value().contains("left half"), "back onto the far half: \(value())")

        // Turned sideways the page fits and is whole; back upright, its first half.
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(2)
        XCTAssertTrue(value().hasPrefix("Page 2 of") && !value().contains("half"), "landscape: whole, \(value())")
        XCUIDevice.shared.orientation = .portrait
        sleep(2)
        XCTAssertTrue(value().hasPrefix("Page 2 of") && value().contains("right half"), "portrait again: the first half, \(value())")

        // Off: the page is whole again (today's behaviour).
        reader.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
        let settings = app.buttons["reader.settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        let toggle = app.switches["reader.splitWidePages"].firstMatch
        for _ in 0..<6 where !(toggle.exists && toggle.isHittable) { app.swipeUp() }
        XCTAssertTrue(toggle.isHittable, "Split Wide Pages in the reader's settings")
        XCTAssertEqual(toggle.value as? String, "1", "on by default")
        toggle.switches.firstMatch.tap()
        app.buttons["Done"].firstMatch.tap()
        sleep(1)
        XCTAssertTrue(value().hasPrefix("Page 2 of") && !value().contains("half"), "off: the whole page, \(value())")
    }

    /// Crop Borders: off by default; on, the page shows its middle (`UITEST_CROP` crops 10% off
    /// each side, as the test account's pages have no margins) and the text boxes stay with it;
    /// off again, the whole page. Progress stays on the simulator.
    func testCropBordersShowsThePagesMiddle() throws {
        app.launchEnvironment["UITEST_CROP"] = "0.1"
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        openReader()
        let cropped = app.descendants(matching: .any)["reader.page.cropped"].firstMatch
        let page = app.descendants(matching: .any)["reader.page"].firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 10))
        XCTAssertFalse(cropped.exists, "off by default")
        let wholeFrame = page.frame
        func setCrop(_ on: Bool) {
            let settings = app.buttons["reader.settings"].firstMatch
            if !settings.exists { reader.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap() }
            XCTAssertTrue(settings.waitForExistence(timeout: 5))
            settings.tap()
            let toggle = app.switches["reader.cropBorders"].firstMatch
            for _ in 0..<8 where !(toggle.exists && toggle.isHittable) { app.swipeUp() }
            XCTAssertTrue(toggle.isHittable, "Crop Borders in the reader's settings")
            if (toggle.value as? String == "1") != on { toggle.switches.firstMatch.tap() }
            app.buttons["Done"].firstMatch.tap()
        }
        setCrop(true)
        XCTAssertTrue(cropped.waitForExistence(timeout: 10), "the page is cropped")
        // Fit to the same screen, the middle 80% is drawn larger than the whole page was.
        XCTAssertGreaterThan(cropped.frame.width * cropped.frame.height, wholeFrame.width * wholeFrame.height * 0.99,
                             "\(cropped.frame) vs \(wholeFrame)")
        snapshot("crop-borders")
        // The next page is measured as it's decoded, and cropped too.
        reader.swipeRight()
        sleep(1)
        XCTAssertTrue(cropped.waitForExistence(timeout: 10), "the next page too")
        setCrop(false)
        XCTAssertTrue(cropped.waitForNonExistence(timeout: 5), "off: whole again")
    }

    /// Spreads coming on while reading near a chapter's end (an iPhone turned sideways, the
    /// Duo unfolded) about halve the slots; a page still on screen was built again with its old
    /// slot number, past the new end, and the app crashed. It keeps the page now.
    func testSpreadsComingOnNearTheEndKeepsThePage() throws {
        app.launchEnvironment["UITEST_READER_OPENS_AT_END"] = "1"
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        openReader()
        defer { XCUIDevice.shared.orientation = .portrait }
        reader.swipeLeft()   // back in right to left: off the last page
        sleep(1)
        reader.swipeLeft()
        sleep(1)
        let before = try pageCounter()
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(3)
        XCTAssertEqual(app.state, .runningForeground, "still running with spreads on")
        XCTAssertTrue(reader.waitForExistence(timeout: 5))
        let value = reader.value as? String ?? ""
        XCTAssertTrue(value.hasPrefix("Page \(before) of") || value.hasPrefix("Page \(before - 1) of"), "the same page or its spread: \(value)")
        XCUIDevice.shared.orientation = .portrait
        sleep(2)
        XCTAssertEqual(app.state, .runningForeground, "and back")
    }

    /// Adds a series' first volume to the test's reading list (made with the first), then goes
    /// back to the Library home.
    private func addFirstVolume(library: String, series: String, new: Bool) {
        let title = KavitaTestAccount.testCollectionTitle
        let libraryRow = app.buttons[library].firstMatch
        // Libraries are shelves down the Library home, made as they scroll into view.
        _ = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'home.'")).firstMatch.waitForExistence(timeout: 20)
        for _ in 0..<10 where !libraryRow.isHittable { app.swipeUp() }
        XCTAssertTrue(libraryRow.isHittable, "library listed")
        libraryRow.tap()
        let tile = app.buttons["series.\(series)"].firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 20), "series listed")
        tile.tap()
        let volume = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'volume.'")).element(boundBy: 0)
        XCTAssertTrue(volume.waitForExistence(timeout: 20))
        volume.press(forDuration: 1.2)
        app.buttons["chapter.addToReadingList"].firstMatch.tap()
        if new {
            app.buttons["readingLists.new"].firstMatch.tap()
            let field = app.alerts.textFields.firstMatch
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            field.typeText(title)
            app.alerts.buttons["Make"].firstMatch.tap()
        } else {
            let row = app.buttons["readingLists.row.\(title)"].firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 10))
            row.tap()
        }
        // Back to the Library home (tapping its tab again goes to the top of its stack).
        app.tabBars.buttons["Library"].tap()
        app.tabBars.buttons["Library"].tap()
        app.swipeDown()
    }

    private func openCollectionsSheet() {
        let more = app.buttons["series.downloads"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 20))
        more.tap()
        let item = app.buttons["series.collections"].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "Collections in the series menu")
        item.tap()
    }

    private func waitFor(_ timeout: TimeInterval = 45, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            sleep(2)
        }
        return false
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

    /// Whether a strip down the screen's right edge, in its upper third (above the popup's
    /// panel), is all black: no page drawn there.
    private func rightEdgeIsBlack() -> Bool {
        guard let image = app.screenshot().image.cgImage,
              let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return false }
        let perPixel = image.bitsPerPixel / 8
        let scale = CGFloat(image.width) / app.windows.firstMatch.frame.width
        let x0 = image.width - Int(40 * scale), y0 = image.height / 6, y1 = image.height / 3
        for y in stride(from: y0, to: y1, by: 4) {
            for x in stride(from: x0, to: image.width - Int(4 * scale), by: 4) {
                let pixel = bytes + y * image.bytesPerRow + x * perPixel
                if max(pixel[0], pixel[1], pixel[2]) > 40 { return false }
            }
        }
        return true
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
