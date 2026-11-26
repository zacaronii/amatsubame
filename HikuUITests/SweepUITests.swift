import XCTest

/// The beta's UI sweep (SharedUITests/SweepSupport.swift): Hiku's one screen and the pages it
/// opens, each audited.
final class SweepUITests: XCTestCase {
    func testSweep() throws {
        let app = XCUIApplication()
        prepareSweep(app)
        app.launch()
        sleep(3)
        var issues = auditScreen(app, "hiku-main")
        let rows = app.buttons.allElementsBoundByIndex.filter { !$0.identifier.isEmpty && $0.isHittable }.map { $0.identifier }
        for row in rows {
            let element = app.buttons[row].firstMatch
            for _ in 0..<6 where !(element.exists && element.isHittable) { app.swipeUp() }
            guard element.exists, element.isHittable, !row.contains("openSafari") else { continue }
            element.tap()
            sleep(2)
            issues += auditScreen(app, "hiku-\(row)")
            if app.navigationBars.buttons.firstMatch.exists { app.navigationBars.buttons.firstMatch.tap() }
            sleep(1)
        }
        keepSweepIssues(issues, "hiku-sweep-issues")
    }
}
