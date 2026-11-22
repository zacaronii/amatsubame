import XCTest

/// The player says when the stream runs dry (#143). Needs a video served slower than it plays:
/// `TEST_RUNNER_UITEST_PLAYER_SLOW_VIDEO=http://127.0.0.1:<port>/…` (a server on this Mac that
/// sends the start quickly, then a trickle).
final class BufferingUITests: XCTestCase {
    func testBufferingShowsWhileTheStreamIsDry() throws {
        guard let video = ProcessInfo.processInfo.environment["UITEST_PLAYER_SLOW_VIDEO"] else {
            throw XCTSkip("Set TEST_RUNNER_UITEST_PLAYER_SLOW_VIDEO to a slowly served video.")
        }
        let app = XCUIApplication()
        app.launchEnvironment["UITEST_PLAYER"] = "1"
        app.launchEnvironment["UITEST_PLAYER_VIDEO"] = video
        app.launchEnvironment["UITEST_QUALITY_OFFER"] = "1"
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["player.video"].firstMatch.waitForExistence(timeout: 10))
        let buffering = app.descendants(matching: .any)["player.buffering"].firstMatch
        XCTAssertTrue(buffering.waitForExistence(timeout: 40), "the wait is shown")
        XCTAssertTrue(buffering.label.hasPrefix("Buffering"), buffering.label)
        // On a connection slower than the video it says so (it may take a few waits to measure).
        let slow = NSPredicate(format: "label CONTAINS %@", "This video needs")
        let told = expectation(for: slow, evaluatedWith: buffering)
        wait(for: [told], timeout: 60)
        // The offer of a lower quality sits under the box, clear of its text.
        let offer = app.buttons["player.lowerQuality"].firstMatch
        if offer.waitForExistence(timeout: 20) {
            XCTAssertGreaterThanOrEqual(offer.frame.minY, buffering.frame.maxY, "the button is below the box")
        }
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "buffering"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
