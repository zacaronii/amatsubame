import XCTest

/// The README's screenshots (`UITEST_CAPTURE=1`, `scripts/readme-screenshots.sh`): the Watch home
/// with the demo Jellyfin's films, then Sintel playing on the demo Jellyfin (Blender Foundation, CC BY 3.0, with Blender's own Japanese subtitles), a tap on a word
/// of a line, and the popup held for a moment. Needs Miru signed in to that server (`DevSetup`,
/// docs/shared.md); plays muted.
final class ReadmeCaptureUITests: XCTestCase {
    func testReadmeCapture() throws {
        guard ProcessInfo.processInfo.environment["UITEST_CAPTURE"] != nil else { throw XCTSkip("Set UITEST_CAPTURE=1 to record.") }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["UITEST_MUTE"] = "1"
        // Just before "多くの罪なき人の血で汚れている" (1:51.8).
        app.launchEnvironment["UITEST_PLAYER_START"] = "109"
        app.launch()
        // A quick tour: Sintel's poster on the Watch home's shelf, its page, Play, a tap on a word.
        let poster = app.descendants(matching: .any)["home.series.Sintel"].firstMatch
        XCTAssertTrue(poster.waitForExistence(timeout: 30), "signed in to Jellyfin, Sintel on the home")
        readmeScreenshot("readme-1-home", settle: 4)
        poster.tap()
        let play = app.descendants(matching: .any)["series.play"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 15), "its page")
        play.tap()
        let line = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == 'subtitle.line' AND label CONTAINS '汚れて'")).firstMatch
        XCTAssertTrue(line.waitForExistence(timeout: 60), "the line")
        // The list is there at once: give the video time to buffer and reach the line (1:49 → 1:51.8).
        sleep(UInt32(ProcessInfo.processInfo.environment["UITEST_CAPTURE_WAIT"].flatMap(Int.init) ?? 5))
        // 汚 is the 11th of the line's 15 characters.
        line.coordinate(withNormalizedOffset: CGVector(dx: 10.5 / 15, dy: 0.5)).tap()
        let gloss = app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Jitendex'")).firstMatch
        XCTAssertTrue(gloss.waitForExistence(timeout: 30), "dictionary results")
        readmeScreenshot("readme-2-lookup")
    }
}
