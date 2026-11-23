import XCTest

/// Drives the book reader against a Kavita server: needs `UITEST_KAVITA_URL`, `UITEST_KAVITA_KEY`,
/// `UITEST_BOOK_LIBRARY` and `UITEST_BOOK_SERIES` (an EPUB series). Read-only and in memory.
final class BookUITests: XCTestCase {
    private var app: XCUIApplication!
    private var library = ""
    private var series = ""

    override func setUpWithError() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        guard let url = env["UITEST_KAVITA_URL"], let key = env["UITEST_KAVITA_KEY"],
              let library = env["UITEST_BOOK_LIBRARY"], let series = env["UITEST_BOOK_SERIES"] else {
            throw XCTSkip("Set TEST_RUNNER_UITEST_KAVITA_URL/KEY and TEST_RUNNER_UITEST_BOOK_LIBRARY/SERIES to run book UI tests.")
        }
        self.library = library
        self.series = series
        app = XCUIApplication()
        app.launchEnvironment["UITEST_KAVITA_URL"] = url
        app.launchEnvironment["UITEST_KAVITA_KEY"] = key
        if let dictionaries = env["UITEST_DICTIONARY_ZIPS"] { app.launchEnvironment["UITEST_DICTIONARY_ZIPS"] = dictionaries }
        XCUIDevice.shared.orientation = .portrait
    }

    private var page: XCUIElement { app.descendants(matching: .any)["book.page"].firstMatch }

    private func openBook() {
        app.launch()
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
        XCTAssertTrue(page.waitForExistence(timeout: 60), "book didn't open")
        sleep(3)
    }

    private func position() -> String { page.value as? String ?? "" }

    /// Auto-scroll in the Scrolling layout: at the reading speed shown in characters a minute, it
    /// moves the place on by itself, waits while the controls show, and closes from its capsule.
    func testAutoScrollInTheScrollingLayout() throws {
        openBook()
        page.tap()
        let settings = app.buttons["reader.settings"].firstMatch
        if !settings.exists { page.tap() }
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        // Layout ▸ Pages, a menu further down the sheet.
        let pages = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Pages'")).firstMatch
        for _ in 0..<4 where !(pages.exists && pages.isHittable) { app.swipeUp() }
        pages.tap()
        app.buttons["Scrolling"].firstMatch.tap()
        app.buttons["Done"].firstMatch.tap()
        sleep(3)
        let start = app.buttons["reader.autoScroll"].firstMatch
        if !start.exists { page.tap() }
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.tap()
        // The test book opens on its cover, a picture page: it stays a few seconds before the
        // next section (a page with nothing to scroll isn't flashed by).
        let started = Date()
        func section() -> String { String(position().split(separator: ",").first ?? "") }
        let cover = section()
        while section() == cover, Date().timeIntervalSince(started) < 20 { usleep(250_000) }
        let stayed = Date().timeIntervalSince(started)
        let note = XCTAttachment(string: "cover stayed \(stayed) s"); note.name = "cover dwell"; note.lifetime = .keepAlways; add(note)
        XCTAssertGreaterThan(stayed, 4, "the picture page stays")
        XCTAssertLessThan(stayed, 12, "and then moves on")
        let speed = app.staticTexts["autoScroll.speed"].firstMatch
        XCTAssertTrue(speed.waitForExistence(timeout: 5))
        XCTAssertEqual(speed.value as? String, "300 characters a minute")
        // The fastest, to see it move in a few seconds.
        for _ in 0..<14 { app.buttons["autoScroll.faster"].firstMatch.tap() }
        XCTAssertEqual(speed.value as? String, "1000 characters a minute")
        // Scrolling reads "…, N characters read": it goes up (past the cover, through the text).
        func read() -> Int { Int(position().split(separator: ",").last?.split(separator: " ").first ?? "") ?? -1 }
        let before = read()
        let moved = expectation(for: NSPredicate { _, _ in read() > before + 50 }, evaluatedWith: nil)
        wait(for: [moved], timeout: 60)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "auto-scroll-book"
        shot.lifetime = .keepAlways
        add(shot)
        // A tap on the page (a lookup on a word, or the controls beside one): it waits.
        page.tap()
        sleep(2)
        let held = read()
        sleep(6)
        XCTAssertEqual(read(), held, "waits while the lookup or the controls show")
        // Closed again (a tap on the page while the controls or a lookup show only closes them):
        // it carries on.
        let close = app.buttons["autoScroll.close"].firstMatch
        for _ in 0..<2 where !close.exists {
            page.tap()
            sleep(2)
        }
        XCTAssertTrue(close.waitForExistence(timeout: 5), "the capsule is back")
        let again = expectation(for: NSPredicate { _, _ in read() > held + 50 }, evaluatedWith: nil)
        wait(for: [again], timeout: 60)
        close.tap()
        XCTAssertTrue(speed.waitForNonExistence(timeout: 5))
    }

    /// Word marks on a book page (a screenshot to check by eye; with no Anki set up every
    /// dictionary word is "not in Anki"). Needs `UITEST_DICTIONARY_ZIPS`.
    func testBookPageShowsWordMarks() throws {
        guard app.launchEnvironment["UITEST_DICTIONARY_ZIPS"] != nil else { throw XCTSkip("Needs UITEST_DICTIONARY_ZIPS.") }
        openBook()
        sleep(8)
        snapshot("book-word-marks")
    }

    /// Book series show progress as a percentage or in characters (for volumes on the device),
    /// never Kavita's page counts, and opening the series downloads nothing.
    func testSeriesShowsCharacterProgress() throws {
        app.launch()
        let libraryRow = app.buttons[library].firstMatch
        XCTAssertTrue(libraryRow.waitForExistence(timeout: 20))
        // Libraries are shelves further down the Library home.
        for _ in 0..<6 where !libraryRow.isHittable { app.swipeUp() }
        libraryRow.tap()
        let tile = app.buttons["series.\(series)"].firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 20))
        tile.tap()
        // A fresh (in-memory) app has no books on the device: percentages, no downloads.
        let total = app.staticTexts.matching(NSPredicate(format: "label ENDSWITH '% read'")).firstMatch
        XCTAssertTrue(total.waitForExistence(timeout: 30), "series progress as a percentage")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS ' pages'")).firstMatch.exists, "no page counts for books")
        snapshot("series-characters")
    }

    func testBookOpensAndPagesTurn() throws {
        openBook()
        snapshot("book-open")
        let start = position()
        XCTAssertTrue(start.hasPrefix("Section"), "position: \(start)")
        // Vertical right-to-left books go forward with a swipe to the right.
        page.swipeRight()
        sleep(2)
        XCTAssertNotEqual(position(), start, "a swipe turns the page")
        snapshot("book-next")
        page.swipeRight()
        sleep(2)
        snapshot("book-contents-page")
        page.swipeLeft()
        sleep(2)
        page.swipeLeft()
        sleep(2)
        XCTAssertEqual(position(), start, "swiping back returns")
    }

    /// Pages through the opening sections and checks no character is cut by a page edge or
    /// shown on two pages (the reader audits each section in UI-test runs).
    func testPagesNeitherCutNorRepeatText() throws {
        app.launchEnvironment["UITEST_BOOK_AUDIT"] = "1"
        openBook()
        // Jump to the contents page from the controls, then read forward through chapter 1.
        page.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.985)).tap()
        let contents = app.buttons["Contents"].firstMatch
        XCTAssertTrue(contents.waitForExistence(timeout: 5))
        contents.tap()
        let entries = app.collectionViews.firstMatch.buttons
        XCTAssertTrue(entries.element(boundBy: 0).waitForExistence(timeout: 5))
        entries.element(boundBy: 0).tap()
        sleep(3)
        for _ in 0..<6 { page.swipeRight(); sleep(2) }
        let audit = app.staticTexts["book.audit"].firstMatch
        XCTAssertTrue(audit.waitForExistence(timeout: 5))
        let report = audit.label
        let attachment = XCTAttachment(string: report)
        attachment.name = "audit"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertFalse(report.isEmpty, "no sections audited")
        XCTAssertNil(report.range(of: #""cut":[1-9]"#, options: .regularExpression), "cut characters: \(report)")
        XCTAssertNil(report.range(of: #""repeated":[1-9]"#, options: .regularExpression), "repeated characters: \(report)")
    }

    /// The reader's glass bar, the settings sheet, and hidden furigana (screenshots to check by eye).
    func testReaderBarSettingsAndHiddenFurigana() throws {
        openBook()
        page.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.985)).tap()
        let settings = app.buttons["reader.settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5), "reader controls")
        sleep(1)
        snapshot("reader-bar")
        settings.tap()
        XCTAssertTrue(app.descendants(matching: .any)["settings.theme"].firstMatch.waitForExistence(timeout: 5), "settings sheet")
        app.swipeUp()
        sleep(1)
        snapshot("reader-settings")
        let furigana = app.buttons["settings.furigana"].firstMatch
        for _ in 0..<3 where !furigana.isHittable { app.swipeUp() }
        furigana.tap()
        let hidden = app.buttons["Hidden"].firstMatch
        XCTAssertTrue(hidden.waitForExistence(timeout: 5), "furigana choices")
        hidden.tap()
        app.buttons["Done"].firstMatch.tap()
        // Jump to chapter 1 (it has furigana) and look; the controls are still showing.
        let contents = app.buttons["Contents"].firstMatch
        if !contents.waitForExistence(timeout: 3) { page.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.985)).tap() }
        XCTAssertTrue(contents.waitForExistence(timeout: 5))
        contents.tap()
        let entries = app.collectionViews.firstMatch.buttons
        XCTAssertTrue(entries.element(boundBy: 1).waitForExistence(timeout: 5))
        entries.element(boundBy: 1).tap()
        sleep(3)
        snapshot("furigana-hidden")
    }

    /// Jumps to chapter 1 with the table of contents: shows the controls (a tap in the bottom
    /// margin, where there's never text), opens Contents and picks the first entry after "Contents"
    /// (or the entry at `entry`).
    private func openFirstChapter(entry: Int = 1) {
        page.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.985)).tap()
        let contents = app.buttons["Contents"].firstMatch
        XCTAssertTrue(contents.waitForExistence(timeout: 5), "reader controls")
        contents.tap()
        let entries = app.collectionViews.firstMatch.buttons
        XCTAssertTrue(entries.element(boundBy: entry).waitForExistence(timeout: 5), "table of contents")
        entries.element(boundBy: entry).tap()
        sleep(3)
    }

    private var popup: XCUIElement { app.webViews.matching(identifier: "lookup.results").firstMatch }

    func testTappingTextOpensLookup() throws {
        guard ProcessInfo.processInfo.environment["UITEST_DICTIONARY_ZIPS"] != nil else { throw XCTSkip("Needs UITEST_DICTIONARY_ZIPS.") }
        openBook()
        XCTAssertTrue(try lookUpInFirstChapter(), "lookup popup opened")
        snapshot("book-lookup")
    }

    /// Back from the background, closing the popup has to take the word's mark off the screen,
    /// and it mustn't come back with the next lookup (WebKit went on showing the page as painted
    /// before, until a page turn). Marks are yellow; with no Anki set up nothing else on the page is.
    func testLookupMarkGoesAfterTheAppWasInTheBackground() throws {
        guard ProcessInfo.processInfo.environment["UITEST_DICTIONARY_ZIPS"] != nil else { throw XCTSkip("Needs UITEST_DICTIONARY_ZIPS.") }
        openBook()
        XCTAssertTrue(try lookUpInFirstChapter(), "no word found to look up")
        XCTAssertGreaterThan(try markedPixels(), markedMinimum, "the looked-up word is marked")

        XCUIDevice.shared.press(.home)
        sleep(15)
        app.activate()
        XCTAssertTrue(popup.waitForExistence(timeout: 10), "popup still open")
        sleep(2)
        closePopup()
        XCTAssertLessThan(try markedPixels(), markedMinimum, "the mark stayed after closing")

        // Another word further down, then close that too.
        XCTAssertTrue(lookUp(dy: 0.45), "no second word found to look up")
        closePopup()
        snapshot("book-marks-cleared")
        XCTAssertLessThan(try markedPixels(), markedMinimum, "a mark came back after the second lookup")
    }

    /// A page after a section's first: the body has moved (a page turn), and WebKit didn't repaint
    /// a mark drawn inside it, so the looked-up word showed no mark (in 小説 君の名は。).
    func testLookupMarkShowsAfterAPageTurn() throws {
        guard ProcessInfo.processInfo.environment["UITEST_DICTIONARY_ZIPS"] != nil else { throw XCTSkip("Needs UITEST_DICTIONARY_ZIPS.") }
        openBook()
        openFirstChapter()
        // Forward (a swipe right in right-to-left books) until a section's second page or later.
        let laterPage = /page ([2-9]|\d\d+) of/
        for _ in 0..<8 where (page.value as? String)?.contains(laterPage) != true {
            page.swipeRight()
            sleep(2)
        }
        XCTAssertTrue((page.value as? String)?.contains(laterPage) == true, "no section with a second page: \(page.value ?? "")")
        XCTAssertLessThan(try markedPixels(), markedMinimum, "a mark before any lookup")
        XCTAssertTrue(lookUp(dy: 0.25) || lookUp(dy: 0.45), "no word found to look up")
        snapshot("book-mark-after-turn")
        XCTAssertGreaterThan(try markedPixels(), markedMinimum, "the looked-up word is marked")
        closePopup()
        XCTAssertLessThan(try markedPixels(), markedMinimum, "the mark stayed after closing")
    }

    /// A highlight with a note and a bookmark go to the test account's Kavita
    /// (`UITEST_SENDS_MARKS`), show in the series' list, open the book at their place from there,
    /// and are removed again: Kavita's annotations end as they began. The book's text is never
    /// asserted on or printed (screenshots stay with the result, out of the repository).
    func testHighlightNoteAndBookmarkReachKavita() throws {
        guard ProcessInfo.processInfo.environment["UITEST_DICTIONARY_ZIPS"] != nil else { throw XCTSkip("Needs UITEST_DICTIONARY_ZIPS.") }
        let kavita = try KavitaTestAccount()
        let marksBefore = try kavita.snapshot(bookSeries: series)
        // Whatever happens, the test account ends as it began.
        addTeardownBlock { XCTAssertNil(try marksBefore.restore(), "the test account's marks were put back") }
        let before = marksBefore.annotations.count
        app.launchEnvironment["UITEST_SENDS_MARKS"] = "1"
        openBook()
        // An ordinary page of text: a section's second page or later (the first pages of a
        // book are covers, contents and headings).
        openFirstChapter()
        let laterPage = /page ([2-9]|\d\d+) of/
        for _ in 0..<8 where (page.value as? String)?.contains(laterPage) != true {
            page.swipeRight()
            sleep(2)
        }
        XCTAssertTrue(lookUp(dy: 0.25) || lookUp(dy: 0.45), "a word to look up")
        let place = position()

        // Highlight its sentence in the third colour, and write a note on it.
        let colour = app.buttons["highlight.colour.2"].firstMatch
        XCTAssertTrue(colour.waitForExistence(timeout: 5), "the highlight bar above the popup")
        colour.tap()
        XCTAssertTrue(app.descendants(matching: .any)["highlight.bar.highlighted"].waitForExistence(timeout: 5), "highlighted")
        app.buttons["highlight.note"].firstMatch.tap()
        let note = app.textViews["note.text"].firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        note.tap()
        note.typeText("test note")
        app.buttons["note.save"].firstMatch.tap()
        sleep(1)
        snapshot("book-highlighted")
        closePopup()
        XCTAssertGreaterThan(try markedPixels(), markedMinimum, "the highlight is drawn on the page (yellow)")
        snapshot("book-highlight-on-page")
        XCTAssertTrue(waitFor { (try? kavita.annotations())?.contains { $0["commentPlainText"] as? String == "test note" && $0["selectedSlotIndex"] as? Int == 2 } == true },
                      "the highlight and its note reached Kavita")

        // Bookmark the place.
        page.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.985)).tap()
        let bookmark = app.buttons["reader.bookmark"].firstMatch
        XCTAssertTrue(bookmark.waitForExistence(timeout: 5))
        bookmark.tap()
        XCTAssertEqual(bookmark.value as? String, "Bookmarked")

        // The series lists both once Kavita has them; the highlight opens the book at its page.
        app.buttons["reader.close"].firstMatch.tap()
        let rows = app.buttons.matching(identifier: "series.mark")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 20))
        XCTAssertTrue(waitFor { rows.count == 2 && !rows.allElementsBoundByIndex.contains { $0.label.contains("Not on Kavita yet") } },
                      "both listed and sent")
        for _ in 0..<10 where !rows.element(boundBy: 0).isHittable { app.swipeUp() }
        snapshot("series-marks")
        rows.element(boundBy: 0).tap()
        XCTAssertTrue(page.waitForExistence(timeout: 60))
        sleep(3)
        XCTAssertEqual(position().split(separator: ",").first, place.split(separator: ",").first, "opened at the mark's page")
        page.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.985)).tap()
        XCTAssertTrue(app.buttons["reader.close"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["reader.close"].firstMatch.tap()

        // Remove both from the list (hold → Remove).
        for _ in 0..<2 {
            let row = rows.firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 10))
            for _ in 0..<10 where !row.isHittable { app.swipeUp() }
            row.press(forDuration: 1.2)
            let remove = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Remove'")).firstMatch
            XCTAssertTrue(remove.waitForExistence(timeout: 5))
            remove.tap()
            sleep(1)
        }
        XCTAssertTrue(waitFor { (try? kavita.annotations().count) == before },
                      "removed from Kavita again (annotations: \((try? kavita.annotations().count) ?? -1), expected \(before))")
        // Kavita's bookmarks are listed per volume: a refresh that still found it would list it again.
        app.swipeDown()
        app.swipeDown()
        sleep(5)
        XCTAssertEqual(rows.count, 0, "nothing comes back from Kavita")
        XCTAssertEqual(Set(try kavita.bookBookmarks(series: series)), marksBefore.bookBookmarks, "the bookmark is gone from Kavita")
    }

    private func waitFor(_ timeout: TimeInterval = 45, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            sleep(2)
        }
        return false
    }

    /// Opens the first Contents entry with words near the top (books start with a cover, a title
    /// page or both) and looks one up. No page shows a mark before.
    private func lookUpInFirstChapter() throws -> Bool {
        for entry in 1...3 {
            openFirstChapter(entry: entry)
            snapshot("book-text")
            XCTAssertLessThan(try markedPixels(), markedMinimum, "a mark before any lookup")
            if lookUp(dy: 0.25) { return true }
        }
        return false
    }

    /// Looks up a word in one of the first body columns at `dy` (vertical text: the first
    /// columns are right of centre). A tap can land between columns or on furigana (which does
    /// nothing): a tap outside text shows the controls, so they're hidden again before the next column.
    private func lookUp(dy: CGFloat) -> Bool {
        for dx in [0.55, 0.5, 0.45, 0.4] {
            page.coordinate(withNormalizedOffset: CGVector(dx: dx, dy: dy)).tap()
            if popup.waitForExistence(timeout: 5) {
                sleep(1)
                return true
            }
            // With the controls showing, a tap on the page only hides them.
            if app.buttons["Contents"].exists { page.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
            sleep(1)
        }
        return false
    }

    /// More marked pixels than stray antialiasing could give; a word's mark has thousands.
    private let markedMinimum = 200

    /// Closes the popup (`closeLookup`); a card (iPad) by a tap in the bottom margin, which never has text.
    private func closePopup() {
        app.closeLookup(outside: page.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.985)))
        XCTAssertTrue(popup.waitForNonExistence(timeout: 5), "popup closed")
        sleep(2)
    }

    /// Pixels of the screen in the lookup mark's yellow (rgba(255, 190, 0, 0.45) over the page),
    /// outside the popup (its tags and chips can be warm colours too).
    private func markedPixels() throws -> Int {
        let image = try XCTUnwrap(app.screenshot().image.cgImage)
        let width = image.width, height = image.height
        let scale = CGFloat(width) / app.frame.width
        let popupFrame = popup.exists ? popup.frame : .null
        let skipped = popupFrame.isNull ? CGRect.null
            : CGRect(x: popupFrame.minX * scale, y: popupFrame.minY * scale, width: popupFrame.width * scale, height: popupFrame.height * scale)
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = try XCTUnwrap(context.data).bindMemory(to: UInt8.self, capacity: width * height * 4)
        var count = 0
        for index in stride(from: 0, to: width * height * 4, by: 4) {
            let pixel = index / 4
            if skipped.contains(CGPoint(x: pixel % width, y: pixel / width)) { continue }
            let red = Int(pixels[index]), green = Int(pixels[index + 1]), blue = Int(pixels[index + 2])
            if red - blue > 30, green - blue > 20, red >= green { count += 1 }
        }
        return count
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
