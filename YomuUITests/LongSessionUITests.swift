import XCTest

/// A long reading session for Instruments (Leaks, Allocations): a manga paged through again and again,
/// then a book. Skipped unless `UITEST_LONG=<minutes>`; in memory against the demo Kavita (read only).
final class LongSessionUITests: XCTestCase {
    func testLongReadingSession() throws {
        guard let minutes = ProcessInfo.processInfo.environment["UITEST_LONG"].flatMap(Double.init) else {
            throw XCTSkip("Set UITEST_LONG=<minutes> to run.")
        }
        let kavita = try DemoServers.kavita()
        let app = XCUIApplication()
        app.launchEnvironment["UITEST_KAVITA_URL"] = kavita[0]
        app.launchEnvironment["UITEST_KAVITA_KEY"] = kavita[1]
        app.launch()
        let end = Date().addingTimeInterval(minutes * 60)
        var round = 0
        while Date() < end {
            for (library, series) in [("サンプル・マンガ", "Pepper&Carrot"), ("サンプル・本", "坊っちゃん")] where Date() < end {
                open(app, library: library, series: series)
                // The manga reader's pages, or the book (its web view) through the app.
                let paged = app.scrollViews["reader.paged"].firstMatch
                let reader: XCUIElement = paged.exists ? paged : app
                // Forward through 30 pages, then back again.
                for direction in [true, false] {
                    for _ in 0..<30 {
                        if direction { reader.swipeRight() } else { reader.swipeLeft() }
                        usleep(400_000)
                    }
                }
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                let close = app.buttons["reader.close"].firstMatch
                if close.waitForExistence(timeout: 5) { close.tap() }
                sleep(1)
                for _ in 0..<3 where app.navigationBars.buttons.firstMatch.exists { app.navigationBars.buttons.firstMatch.tap() }
            }
            round += 1
            print("LONG: round \(round) at \(Date().timeIntervalSince1970)")
        }
    }

    private func open(_ app: XCUIApplication, library: String, series: String) {
        app.tabBars.buttons["Library"].firstMatch.tap()
        let shelf = app.buttons[library].firstMatch
        for _ in 0..<6 where !(shelf.exists && shelf.isHittable) { app.swipeUp() }
        XCTAssertTrue(shelf.waitForExistence(timeout: 20), library)
        shelf.tap()
        let tile = app.buttons["series.\(series)"].firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 20), series)
        tile.tap()
        let start = app.buttons["series.continue"].firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 20))
        start.tap()
        sleep(3)
    }
}
