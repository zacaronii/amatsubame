import XCTest

/// The README's GIF (`UITEST_CAPTURE=1`, recorded with `simctl io recordVideo`): Sintel on the demo
/// Jellyfin (Blender Foundation, CC BY 3.0, with Blender's own Japanese subtitles), a tap on a word
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
        let search = app.buttons["watch.search"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 20), "signed in to Jellyfin")
        search.tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("Sintel")
        let result = app.descendants(matching: .any)["search.result"].firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 15), "Sintel found")
        result.tap()
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
        sleep(4)
    }
}
