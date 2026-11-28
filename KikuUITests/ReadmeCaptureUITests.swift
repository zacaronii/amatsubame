import XCTest

/// The README's screenshots (`UITEST_CAPTURE=1`, `scripts/readme-screenshots.sh`). The lookup: the LibriVox
/// recording of 坊っちゃん (public domain, read by ekzemplaro) with Kaku's own transcript of it
/// (docs/media/capture/kiku), the transcript following the audio, and a tap on a word. In memory and
/// muted; needs `UITEST_CAPTURE_FOLDER` (that folder) and `UITEST_DICTIONARY_ZIPS`.
final class ReadmeCaptureUITests: XCTestCase {
    func testReadmeCapture() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["UITEST_CAPTURE"] != nil, let folder = env["UITEST_CAPTURE_FOLDER"], let dictionaries = env["UITEST_DICTIONARY_ZIPS"] else {
            throw XCTSkip("Set UITEST_CAPTURE=1, UITEST_CAPTURE_FOLDER and UITEST_DICTIONARY_ZIPS to record.")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment = ["UITEST_KIKU": "1", "UITEST_KIKU_CAPTURE": folder, "UITEST_MUTE": "1",
                                 "UITEST_DICTIONARY_ZIPS": dictionaries]
        app.launch()
        let current = app.descendants(matching: .any)["player.currentLine"]
        let line = current.descendants(matching: .any).matching(NSPredicate(format: "identifier == 'subtitle.line' AND label BEGINSWITH '小学校'")).firstMatch
        XCTAssertTrue(line.waitForExistence(timeout: 30), "the transcript reached the line")
        // Let it follow the audio for a moment, then look up 小学校 (the line's first word).
        sleep(3)
        line.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 14, dy: 14)).tap()
        let gloss = app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Jitendex'")).firstMatch
        XCTAssertTrue(gloss.waitForExistence(timeout: 60), "dictionary results")
        readmeScreenshot("readme-2-lookup")
    }

    /// The home: Listen with the demo Audiobookshelf's audiobooks. Needs Kiku signed in to it
    /// (`DevSetup`, docs/shared.md).
    func testReadmeHome() throws {
        guard ProcessInfo.processInfo.environment["UITEST_CAPTURE"] != nil else { throw XCTSkip("Set UITEST_CAPTURE=1 to record.") }
        let app = XCUIApplication()
        app.launchEnvironment["UITEST_MUTE"] = "1"
        app.launch()
        let book = app.descendants(matching: .any)["listen.recentBook"].firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 30), "signed in to Audiobookshelf, its books on Listen")
        readmeScreenshot("readme-1-home", settle: 5)
    }
}
