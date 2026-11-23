import XCTest

/// #166: from two screens deep in Settings (Advanced ▸ a Waiting to Sync kind), tapping the
/// Settings tab again shows Settings' top, and the next tap there opens a screen.
@MainActor
func checkSettingsTabRetap(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
    // iPhone: the tab bar; iPad: the tabs at the top (not a tab bar to XCUITest).
    let bar = app.tabBars.buttons["Settings"]
    let tab = bar.waitForExistence(timeout: 10) ? bar : app.buttons.matching(identifier: "Settings").firstMatch
    tab.tap()
    let advanced = app.descendants(matching: .any)["settings.advanced"].firstMatch
    for _ in 0..<8 where !(advanced.exists && advanced.isHittable) { app.swipeUp() }
    XCTAssertTrue(advanced.isHittable, "Advanced in Settings", file: file, line: line)
    advanced.tap()
    let waiting = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'advanced.waiting.'")).firstMatch
    XCTAssertTrue(waiting.waitForExistence(timeout: 5), "Advanced's Waiting to Sync", file: file, line: line)
    waiting.tap()
    XCTAssertTrue(app.navigationBars.element(boundBy: 0).buttons.firstMatch.waitForExistence(timeout: 5), file: file, line: line)
    XCTAssertFalse(advanced.exists && advanced.isHittable, "two screens deep", file: file, line: line)

    tab.tap()
    XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5), "the top of Settings", file: file, line: line)
    for _ in 0..<8 where !(advanced.exists && advanced.isHittable) { app.swipeUp() }
    XCTAssertTrue(advanced.isHittable, "Advanced again at the top", file: file, line: line)
    advanced.tap()
    XCTAssertTrue(app.navigationBars["Advanced"].waitForExistence(timeout: 5), "the next tap opens a screen", file: file, line: line)
}
