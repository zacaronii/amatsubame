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

    /// A volume's menu marks it read and unread, and the page shows it at once. Only tried on a
    /// volume that hasn't been started, and put back as it was.
    func testMarkingAVolumeReadAndUnread() throws {
        guard let library = ProcessInfo.processInfo.environment["UITEST_LIBRARY"] else {
            throw XCTSkip("Set TEST_RUNNER_UITEST_LIBRARY.")
        }
        let app = XCUIApplication()
        app.launch()
        let link = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", library)).firstMatch
        XCTAssertTrue(link.waitForExistence(timeout: 20))
        link.tap()
        let series = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'series.'")).firstMatch
        XCTAssertTrue(series.waitForExistence(timeout: 15))
        series.tap()
        let volume = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'volume.'")).firstMatch
        XCTAssertTrue(volume.waitForExistence(timeout: 15), "the series' volumes")
        volume.press(forDuration: 1.0)
        let markRead = app.buttons["Mark as Read"].firstMatch
        XCTAssertTrue(markRead.waitForExistence(timeout: 5), "the volume's menu has Mark as Read")
        guard !app.buttons["Mark as Unread"].exists else {
            // Already started: leave its place alone.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05)).tap()
            return
        }
        markRead.tap()
        sleep(1)
        let read = XCTAttachment(screenshot: app.screenshot())
        read.name = "marked read"
        read.lifetime = .keepAlways
        add(read)
        volume.press(forDuration: 1.0)
        let markUnread = app.buttons["Mark as Unread"].firstMatch
        XCTAssertTrue(markUnread.waitForExistence(timeout: 5), "now read, it offers Mark as Unread")
        XCTAssertFalse(app.buttons["Mark as Read"].exists)
        markUnread.tap()
        sleep(2)
        volume.press(forDuration: 1.0)
        XCTAssertTrue(app.buttons["Mark as Read"].firstMatch.waitForExistence(timeout: 5), "unread again")
        XCTAssertFalse(app.buttons["Mark as Unread"].exists)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05)).tap()
    }
}
