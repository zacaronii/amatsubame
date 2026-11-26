import XCTest

/// What a newcomer sees in Hiku (public beta): the app on a device where no other Amatsubame
/// app was ever installed, each of its screens kept as a screenshot to review. Run it first on
/// a fresh simulator: Hiku has no separate test data set.
final class NewUserUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    func testFirstLaunch() {
        let app = XCUIApplication()
        app.launch()
        sleep(3)
        keepScreenshot(app, "hiku-first-launch")
        let rows = app.buttons.allElementsBoundByIndex.filter { !$0.identifier.isEmpty && $0.isHittable }.map { $0.identifier }
        for row in rows {
            let element = app.buttons[row].firstMatch
            for _ in 0..<6 where !element.isHittable { app.swipeUp() }
            guard element.isHittable else { continue }
            element.tap()
            sleep(2)
            keepScreenshot(app, "hiku-\(row)")
            if app.navigationBars.buttons.firstMatch.exists { app.navigationBars.buttons.firstMatch.tap() }
            sleep(1)
        }
        app.swipeUp()
        keepScreenshot(app, "hiku-scrolled")
    }
}
