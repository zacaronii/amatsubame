import XCTest

/// The beta's UI sweep (SharedUITests/SweepSupport.swift): every tab and Settings row, a manga and a
/// book open in the reader, each audited. In memory against the demo Kavita (read only: nothing is
/// sent); skipped while the demo can't be reached.
final class SweepUITests: XCTestCase {
    func testSweep() throws {
        let kavita = try DemoServers.kavita()
        let app = XCUIApplication()
        app.launchEnvironment["UITEST_KAVITA_URL"] = kavita[0]
        app.launchEnvironment["UITEST_KAVITA_KEY"] = kavita[1]
        prepareSweep(app)
        app.launch()
        XCTAssertTrue(sweepTab(app, "Library").waitForExistence(timeout: 20))
        sleep(4)
        var issues = sweepTabsAndSettings(app, prefix: "yomu", tabs: ["Library", "Dictionary", "Stats", "Settings"])

        // A manga and a book from the demo library, each in the reader.
        for (library, series) in [("サンプル・マンガ", "Pepper&Carrot"), ("サンプル・本", "坊っちゃん")] {
            sweepTab(app, "Library").tap()
            let shelf = app.buttons[library].firstMatch
            for _ in 0..<6 where !(shelf.exists && shelf.isHittable) { app.swipeUp() }
            guard shelf.waitForExistence(timeout: 20) else { print("SWEEP: yomu · no library \(library)"); continue }
            shelf.tap()
            let tile = app.buttons["series.\(series)"].firstMatch
            guard tile.waitForExistence(timeout: 20) else { print("SWEEP: yomu · no series \(series)"); continue }
            tile.tap()
            let open = app.buttons["series.continue"].firstMatch
            guard open.waitForExistence(timeout: 20) else { print("SWEEP: yomu · no Start Reading on \(series)"); continue }
            issues += auditScreen(app, "yomu-series-\(series)")
            open.tap()
            sleep(6)
            issues += auditScreen(app, "yomu-reader-\(series)")
            // The reader's controls, then out.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            sleep(1)
            issues += auditScreen(app, "yomu-reader-controls-\(series)")
            let close = app.buttons["reader.close"].firstMatch
            if close.waitForExistence(timeout: 5) { close.tap() }
            sleep(2)
            for _ in 0..<3 where app.navigationBars.buttons.firstMatch.exists { app.navigationBars.buttons.firstMatch.tap() }
        }
        keepSweepIssues(issues, "yomu-sweep-issues")
    }
}
