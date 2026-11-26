import XCTest

/// At the largest accessibility text size a shelf's See All goes below its name instead of
/// squeezing it (the UI sweep's "Text clipped"). In memory against the demo Kavita (read only).
final class LargestTextUITests: XCTestCase {
    func testShelfHeaderStacks() throws {
        let kavita = try DemoServers.kavita()
        let app = XCUIApplication()
        app.launchEnvironment["UITEST_KAVITA_URL"] = kavita[0]
        app.launchEnvironment["UITEST_KAVITA_KEY"] = kavita[1]
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        let seeAll = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'library.seeAll.'")).firstMatch
        for _ in 0..<6 where !(seeAll.exists && seeAll.isHittable) { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(seeAll.waitForExistence(timeout: 20))
        let name = String(seeAll.identifier.dropFirst("library.seeAll.".count))
        let title = app.buttons[name].firstMatch
        XCTAssertTrue(title.exists, "the shelf \(name)")
        keepScreenshot(app, "largest-library")
        XCTAssertGreaterThanOrEqual(seeAll.frame.minY, title.frame.maxY - 1, "See All below the name: \(seeAll.frame) vs \(title.frame)")
    }
}
