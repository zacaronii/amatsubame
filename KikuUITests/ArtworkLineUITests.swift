import XCTest

/// The transcript off: the artwork with the line playing under it. A long line (several rows) and
/// a short one take the same space, so the artwork keeps its size as the lines go by.
final class ArtworkLineUITests: XCTestCase {
    func testTheArtworkKeepsItsSizeAsLinesChange() {
        check(textSize: nil)
    }

    func testTheArtworkKeepsItsSizeAtTheLargestText() {
        check(textSize: "UICTContentSizeCategoryAccessibilityXXXL")
    }

    private func check(textSize: String?) {
        let app = XCUIApplication()
        app.launchEnvironment = ["UITEST_KIKU": "1", "UITEST_KIKU_PLAYER": "1", "UITEST_MUTE": "1"]
        if let textSize { app.launchArguments += ["-UIPreferredContentSizeCategoryName", textSize] }
        app.launch()
        let transcript = app.buttons["player.transcript"].firstMatch
        XCTAssertTrue(transcript.waitForExistence(timeout: 15))
        if transcript.value as? String == "On" { transcript.tap() }
        let line = app.buttons["player.offLine"].firstMatch
        let artwork = app.descendants(matching: .any)["player.artwork"].firstMatch
        XCTAssertTrue(line.waitForExistence(timeout: 5), "the line under the artwork")
        XCTAssertTrue(artwork.exists)

        /// Next line until the line under the artwork starts with `text`; the artwork's and the
        /// line's frames there.
        func frames(at text: String) -> (artwork: CGRect, line: CGRect) {
            let next = app.buttons["player.nextLine"].firstMatch
            for _ in 0..<10 where !line.label.contains(text) { next.tap(); sleep(1) }
            XCTAssertTrue(line.label.contains(text), "reached \(text): \(line.label)")
            return (artwork.frame, line.frame)
        }
        let short = frames(at: "みんなで相談")
        // Not squeezed out by the text (the Duo's folded screen at the largest size leaves about 100 pt).
        XCTAssertGreaterThanOrEqual(short.artwork.height, 80, "the artwork has room: \(short.artwork)")
        let long = frames(at: "雨の日は家で")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "long line \(textSize ?? "default")"
        attachment.lifetime = .keepAlways
        add(attachment)
        let shortAgain = frames(at: "その1番目")
        for (name, other) in [("long", long), ("short again", shortAgain)] {
            XCTAssertEqual(other.artwork, short.artwork, "the artwork moved or resized with the \(name) line")
            XCTAssertEqual(other.line.height, short.line.height, accuracy: 0.5, "the line's box changed height with the \(name) line")
        }
    }
}
