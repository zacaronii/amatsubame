import XCTest

/// A long Lines session for Instruments (Leaks, Allocations): saved transcripts opened again and
/// again, scrolled, and words looked up. Skipped unless `UITEST_LONG=<minutes>`; in memory, and
/// with `UITEST_DICTIONARY_ZIPS` the lookups have results.
final class LongSessionUITests: XCTestCase {
    func testLongLinesSession() throws {
        let env = ProcessInfo.processInfo.environment
        guard let minutes = env["UITEST_LONG"].flatMap(Double.init) else { throw XCTSkip("Set UITEST_LONG=<minutes> to run.") }
        let app = XCUIApplication()
        app.launchEnvironment["UITEST_PLAYER"] = "1"
        app.launchEnvironment["UITEST_TRANSCRIPT"] = "2"
        if let zips = env["UITEST_DICTIONARY_ZIPS"] { app.launchEnvironment["UITEST_DICTIONARY_ZIPS"] = zips }
        app.launch()
        app.tabBars.buttons["Lines"].tap()
        let end = Date().addingTimeInterval(minutes * 60)
        var round = 0
        while Date() < end {
            for index in 0..<2 where Date() < end {
                let episode = app.buttons.matching(identifier: "lines.episode").element(boundBy: index)
                guard episode.waitForExistence(timeout: 10) else { continue }
                episode.tap()
                let lines = app.descendants(matching: .any).matching(identifier: "subtitle.line")
                if lines.firstMatch.waitForExistence(timeout: 10) {
                    for _ in 0..<5 {
                        lines.firstMatch.tap()
                        usleep(800_000)
                        app.closeLookup()
                        usleep(300_000)
                    }
                    app.swipeUp(); app.swipeDown()
                }
                if app.navigationBars.buttons.firstMatch.exists { app.navigationBars.buttons.firstMatch.tap() }
                usleep(500_000)
            }
            round += 1
            print("LONG: round \(round) at \(Date().timeIntervalSince1970)")
        }
    }
}
