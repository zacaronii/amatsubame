import XCTest

/// A long listening session for Instruments (Leaks, Allocations): the capture clip (public domain,
/// docs/media/capture/kiku) played muted with its transcript following, words looked up now and
/// then, and played again at its end. Skipped unless `UITEST_LONG=<minutes>`; in memory. Needs
/// `UITEST_CAPTURE_FOLDER` and `UITEST_DICTIONARY_ZIPS`.
final class LongSessionUITests: XCTestCase {
    func testLongListeningSession() throws {
        let env = ProcessInfo.processInfo.environment
        guard let minutes = env["UITEST_LONG"].flatMap(Double.init), let folder = env["UITEST_CAPTURE_FOLDER"],
              let zips = env["UITEST_DICTIONARY_ZIPS"] else {
            throw XCTSkip("Set UITEST_LONG=<minutes>, UITEST_CAPTURE_FOLDER and UITEST_DICTIONARY_ZIPS to run.")
        }
        let app = XCUIApplication()
        app.launchEnvironment = ["UITEST_KIKU": "1", "UITEST_KIKU_CAPTURE": folder, "UITEST_MUTE": "1", "UITEST_DICTIONARY_ZIPS": zips]
        app.launch()
        let playPause = app.buttons["player.playPause"]
        XCTAssertTrue(playPause.waitForExistence(timeout: 30))
        let end = Date().addingTimeInterval(minutes * 60)
        var round = 0
        while Date() < end {
            sleep(15)
            let line = app.descendants(matching: .any)["player.currentLine"].descendants(matching: .any)["subtitle.line"].firstMatch
            if line.exists {
                line.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 14, dy: 14)).tap()
                sleep(2)
                app.closeLookup()
            }
            // At the clip's end, from the start again.
            if (playPause.value as? String) != "playing" {
                for _ in 0..<6 { app.swipeDown(velocity: .fast) }
                let first = app.buttons.matching(identifier: "player.lineTime").firstMatch
                if first.exists { first.tap() }
                if (playPause.value as? String) != "playing" { playPause.tap() }
            }
            round += 1
            print("LONG: round \(round) at \(Date().timeIntervalSince1970)")
        }
    }
}
