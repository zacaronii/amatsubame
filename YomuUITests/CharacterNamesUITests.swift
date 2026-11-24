import XCTest

/// The character names dictionary in Yomu, with AniList and MangaBaka answered from the Names
/// package's made-up fixtures (`UITEST_NAMES_FIXTURES`): the series page's picker, the cast in
/// while a book is open, and out when it closes. Needs `UITEST_KAVITA_URL`, `UITEST_KAVITA_KEY`,
/// `UITEST_BOOK_LIBRARY` and `UITEST_BOOK_SERIES` (an EPUB series), like BookUITests.
final class CharacterNamesUITests: XCTestCase {
    private var app: XCUIApplication!
    private var library = ""
    private var series = ""

    override func setUpWithError() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        guard let url = env["UITEST_KAVITA_URL"], let key = env["UITEST_KAVITA_KEY"],
              let library = env["UITEST_BOOK_LIBRARY"], let series = env["UITEST_BOOK_SERIES"] else {
            throw XCTSkip("Set TEST_RUNNER_UITEST_KAVITA_URL/KEY and TEST_RUNNER_UITEST_BOOK_LIBRARY/SERIES.")
        }
        self.library = library
        self.series = series
        app = XCUIApplication()
        app.launchEnvironment["UITEST_KAVITA_URL"] = url
        app.launchEnvironment["UITEST_KAVITA_KEY"] = key
        // The made-up casts and searches the Names package tests use.
        let fixtures = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Packages/Names/Tests/NamesTests/Fixtures")
        app.launchEnvironment["UITEST_NAMES_FIXTURES"] = fixtures.path(percentEncoded: false)
        XCUIDevice.shared.orientation = .portrait
    }

    private func openSeries() {
        app.launch()
        let libraryRow = app.buttons[library].firstMatch
        XCTAssertTrue(libraryRow.waitForExistence(timeout: 20), "library \(library) not listed")
        for _ in 0..<6 where !libraryRow.isHittable { app.swipeUp() }
        libraryRow.tap()
        let tile = app.buttons["series.\(series)"].firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 20), "series \(series) not found")
        tile.tap()
        XCTAssertTrue(app.buttons["series.continue"].firstMatch.waitForExistence(timeout: 20))
    }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testTheOpenSeriesCastIsInTheDictionary() throws {
        openSeries()
        // The series page's picker: AniList's (made-up) results for its title.
        app.buttons["series.downloads"].firstMatch.tap()
        let names = app.buttons["series.characterNames"].firstMatch
        XCTAssertTrue(names.waitForExistence(timeout: 5))
        names.tap()
        let result = app.buttons.matching(NSPredicate(format: "label CONTAINS '架空の物語' AND label CONTAINS 'Manga'")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 15), "the picker's results")
        attach("picker")
        result.tap()
        XCTAssertTrue(result.waitForNonExistence(timeout: 10), "picked, the sheet closes")

        // Reading: its cast is in the dictionary (the four named characters).
        app.buttons["series.continue"].firstMatch.tap()
        let state = app.descendants(matching: .any)["reader.characterNames"].firstMatch
        XCTAssertTrue(state.waitForExistence(timeout: 60), "the reader opened")
        let ready = NSPredicate(format: "label CONTAINS 'ready(characters: 4)'")
        XCTAssertEqual(XCTWaiter().wait(for: [expectation(for: ready, evaluatedWith: state)], timeout: 30), .completed, state.label)

        // Closed: the cast goes, and with nothing open, the dictionary.
        let page = app.descendants(matching: .any)["book.page"].firstMatch
        page.tap()
        let close = app.buttons["reader.close"].firstMatch
        if !close.waitForExistence(timeout: 3) { page.tap() }
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.tap()
        app.buttons["Settings"].firstMatch.tap()
        let dictionaries = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Dictionaries'")).firstMatch
        XCTAssertTrue(dictionaries.waitForExistence(timeout: 10))
        dictionaries.tap()
        let toggle = app.switches["dictionaries.characterNames"].firstMatch
        for _ in 0..<6 where !toggle.exists { app.swipeUp() }
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), "the Character Names section")
        attach("settings after closing")
        let installed = app.staticTexts.matching(NSPredicate(format: "label == 'Character Names'")).count
        XCTAssertLessThanOrEqual(installed, 1, "only the section's header: the dictionary itself is gone")
    }
}
