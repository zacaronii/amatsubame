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

    func testTappingTextOpensLookup() throws {
        guard ProcessInfo.processInfo.environment["UITEST_DICTIONARY_ZIPS"] != nil else { throw XCTSkip("Needs UITEST_DICTIONARY_ZIPS.") }
        openBook()
        // Jump to chapter 1 with the table of contents: show the controls (a tap in the bottom
        // margin, where there's never text), open Contents and pick the first entry after "Contents".
        page.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.985)).tap()
        let contents = app.buttons["Contents"].firstMatch
        XCTAssertTrue(contents.waitForExistence(timeout: 5), "reader controls")
        contents.tap()
        let entries = app.collectionViews.firstMatch.buttons
        XCTAssertTrue(entries.element(boundBy: 1).waitForExistence(timeout: 5), "table of contents")
        entries.element(boundBy: 1).tap()
        sleep(3)
        snapshot("book-text")
        // Vertical text: the first columns are on the right.
        // The first body column, right of centre (the chapter heading and its picture are further right).
        page.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.25)).tap()
        let popup = app.webViews.matching(identifier: "lookup.results").firstMatch
        XCTAssertTrue(popup.waitForExistence(timeout: 15), "lookup popup opened")
        snapshot("book-lookup")
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
