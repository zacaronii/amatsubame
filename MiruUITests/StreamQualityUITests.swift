import XCTest

/// A lower streaming quality plays through Jellyfin's transcoder. Live: needs Miru signed in on
/// the simulator (`DevSetup`, docs/shared.md), `TEST_RUNNER_UITEST_SEARCH_QUERY` (text that finds
/// a show there whose files are over 1 Mbps) and `TEST_RUNNER_UITEST_STREAM_QUALITY=1000000`.
final class StreamQualityUITests: XCTestCase {
    private func snapshot(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testALowerQualityPlaysTranscoded() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let query = environment["UITEST_SEARCH_QUERY"], let quality = environment["UITEST_STREAM_QUALITY"] else {
            throw XCTSkip("Set TEST_RUNNER_UITEST_SEARCH_QUERY and TEST_RUNNER_UITEST_STREAM_QUALITY.")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["UITEST_MUTE"] = "1"
        app.launchEnvironment["UITEST_STREAM_QUALITY"] = quality
        app.launch()
        let search = app.buttons["watch.search"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 20), "signed in to Jellyfin")
        search.tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText(query)
        let result = app.descendants(matching: .any)["search.result"].firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 15), "something found")
        result.tap()
        let play = app.descendants(matching: .any)["series.play"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 15), "the show's page")
        play.tap()
        XCTAssertTrue(app.descendants(matching: .any)["player.video"].firstMatch.waitForExistence(timeout: 20), "the player")

        // The stream's details (I) say what's playing, and the picture is moving.
        let info = app.descendants(matching: .any)["player.streamInfo"].firstMatch
        for _ in 0..<12 where !info.exists {
            sleep(3)
            app.typeKey("i", modifierFlags: [])
            _ = info.waitForExistence(timeout: 2)
        }
        XCTAssertTrue(info.exists, "stream info")
        // (A limit above the file's own size plays the original: the same steps, for comparison.)
        if (Int(quality) ?? 0) < 50_000_000 {
            XCTAssertTrue(info.label.contains("transcoded"), "Quality: transcoded (\(info.label))")
        }
        snapshot(app, "transcoded")

        // A jump to the middle carries on from there (the server starts transcoding at that point).
        let scrubber = app.descendants(matching: .any)["player.scrubber"].firstMatch
        XCTAssertTrue(scrubber.waitForExistence(timeout: 5))
        scrubber.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.5))
            .press(forDuration: 0.2, thenDragTo: scrubber.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
        sleep(12)
        snapshot(app, "after seeking")
        let first = scrubber.value as? String
        sleep(5)
        snapshot(app, "five seconds on")
        XCTAssertNotEqual(scrubber.value as? String, first, "playing on after the seek")
    }
}
