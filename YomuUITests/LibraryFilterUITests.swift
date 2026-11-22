import XCTest

/// A library's grid on iPhone: the Filter and Sort menu beside All · Reading · Downloaded.
/// Needs Yomu signed in to Kavita on the simulator (`DevSetup`, docs/shared.md) and
/// `TEST_RUNNER_UITEST_LIBRARY` (a library's name).
final class LibraryFilterUITests: XCTestCase {
    func testFilterMenuIsThere() throws {
        guard let library = ProcessInfo.processInfo.environment["UITEST_LIBRARY"] else {
            throw XCTSkip("Set TEST_RUNNER_UITEST_LIBRARY.")
        }
        let app = XCUIApplication()
        app.launch()
        let link = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", library)).firstMatch
        XCTAssertTrue(link.waitForExistence(timeout: 20), "the library is on the home screen")
        link.tap()
        let menu = app.descendants(matching: .any)["library.filterMenu"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 10), "the filter and sort menu")
        XCTAssertTrue(app.descendants(matching: .any)["shelf.filter"].firstMatch.exists)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "library grid"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
