import XCTest

/// What one audit found (its handler can't capture a local array under Swift 6).
final class SweepIssues: @unchecked Sendable {
    var lines: [String] = []
}

/// The beta's UI sweep: every tab and Settings row of an app, each with a screenshot kept in the
/// result and XCTest's accessibility audit run on it. Issues don't fail the test: each is printed
/// as a `SWEEP:` line (to collect across the device matrix) and kept in one attachment.
/// `UITEST_SWEEP_TEXT=xxxl` runs it at the largest accessibility text size, `UITEST_SWEEP_LANDSCAPE=1`
/// in landscape; dark mode comes from the simulator (`simctl ui <device> appearance dark`).
extension XCTestCase {
    /// Applies the sweep's text size to `app` before it launches.
    func prepareSweep(_ app: XCUIApplication) {
        let env = ProcessInfo.processInfo.environment
        if env["UITEST_SWEEP_TEXT"] == "xxxl" {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        XCUIDevice.shared.orientation = env["UITEST_SWEEP_LANDSCAPE"] != nil ? .landscapeLeft : .portrait
    }

    /// The screen as it is now: a screenshot, and the audit's issues (also printed).
    @discardableResult
    func auditScreen(_ app: XCUIApplication, _ name: String) -> [String] {
        keepScreenshot(app, name)
        let found = SweepIssues()
        try? app.performAccessibilityAudit(for: .all) { @Sendable issue in
            // The audit calls this on the main thread, while it runs.
            nonisolated(unsafe) let issue = issue
            MainActor.assumeIsolated {
                let element = issue.element.map { "\($0.elementType.rawValue) '\($0.label.prefix(40))' [\($0.identifier)]" } ?? "-"
                let line = "\(name) · \(issue.auditType) · \(issue.compactDescription) · \(element)"
                found.lines.append(line)
                print("SWEEP: \(line)")
            }
            return true
        }
        return found.lines
    }

    /// A tab: in the tab bar on an iPhone, a sidebar cell where the tabs adapt into one (iPad,
    /// the iPhone Duo's inner screen).
    func sweepTab(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        let bar = app.tabBars.buttons[name].firstMatch
        if bar.exists { return bar }
        // A sidebar collapsed by a page opened from it comes back first.
        let showSidebar = app.buttons["ToggleSidebar"].firstMatch
        if !app.cells[name].exists, showSidebar.exists, showSidebar.label == "Show Sidebar" { showSidebar.tap(); sleep(1) }
        let cell = app.cells[name].firstMatch
        if cell.exists { return cell }
        // Tab buttons outside a tab bar (the iPad's top bar, the iPhone Duo's rail), identified by
        // their symbols ("gearshape", "books.vertical").
        let rail = app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != '' AND NOT (identifier BEGINSWITH 'settings.')", name)).firstMatch
        return rail.exists ? rail : cell
    }

    /// Every tab, then the top level of every Settings row: audited, with screenshots.
    func sweepTabsAndSettings(_ app: XCUIApplication, prefix: String, tabs: [String]) -> [String] {
        var issues: [String] = []
        for tab in tabs {
            let element = sweepTab(app, tab)
            guard element.waitForExistence(timeout: 10) else { print("SWEEP: \(prefix) · no tab \(tab)"); continue }
            element.tap()
            sleep(3)
            issues += auditScreen(app, "\(prefix)-tab-\(tab)")
        }
        guard tabs.contains("Settings") else { return issues }
        sweepTab(app, "Settings").tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
        var rows: [String] = []
        let settingsRows = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'settings.'"))
        // Swipes go to the Settings list itself (on a split layout the screen's middle is another column).
        let list = app.navigationBars["Settings"].exists
            ? app.collectionViews.containing(NSPredicate(format: "identifier BEGINSWITH 'settings.'")).firstMatch : app
        let surface: XCUIElement = list.exists ? list : app
        for _ in 0..<10 {
            sleep(1)
            rows += Set(settingsRows.allElementsBoundByIndex.map { $0.identifier }.filter { !rows.contains($0) }).sorted()
            surface.swipeUp(velocity: .fast)
        }
        // On screen by its frame: `isHittable` fails the test outright for a row in another column.
        let window = app.windows.firstMatch.frame
        func onScreen(_ element: XCUIElement) -> Bool {
            element.exists && !element.frame.isEmpty && window.contains(CGPoint(x: element.frame.midX, y: element.frame.midY))
        }
        for row in rows {
            let element = app.descendants(matching: .any)[row].firstMatch
            for _ in 0..<10 where !onScreen(element) { surface.swipeDown(velocity: .fast) }
            for _ in 0..<10 where !onScreen(element) { surface.swipeUp(velocity: .slow) }
            guard onScreen(element) else { print("SWEEP: \(prefix) · unreachable row \(row)"); continue }
            element.tap()
            sleep(2)
            issues += auditScreen(app, "\(prefix)-settings-\(row.dropFirst("settings.".count))")
            if app.navigationBars.buttons.firstMatch.exists { app.navigationBars.buttons.firstMatch.tap() }
            sleep(1)
        }
        return issues
    }

    /// Keeps every issue in one text attachment.
    func keepSweepIssues(_ issues: [String], _ name: String) {
        let attachment = XCTAttachment(string: issues.isEmpty ? "No issues." : issues.joined(separator: "\n"))
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
