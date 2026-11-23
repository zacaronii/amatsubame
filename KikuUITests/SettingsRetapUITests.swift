import XCTest

/// #166 in Kiku (in memory).
final class SettingsRetapUITests: XCTestCase {
    @MainActor
    func testSettingsTabReturnsToTheTopFromTwoScreensDeep() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment = ["UITEST_KIKU": "1"]
        app.launch()
        checkSettingsTabRetap(app)
    }

    /// The issue's own path: Settings ▸ Kaku (signed in, read only) ▸ Connection.
    @MainActor
    func testSettingsTabReturnsToTheTopFromKakuConnection() throws {
        let env = ProcessInfo.processInfo.environment
        guard let url = env["UITEST_KAKU_URL"], let token = env["UITEST_KAKU_TOKEN"] else {
            throw XCTSkip("Set TEST_RUNNER_UITEST_KAKU_URL and TEST_RUNNER_UITEST_KAKU_TOKEN.")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment = ["UITEST_KIKU": "1"]
        app.launch()
        let tab = app.tabBars.buttons["Settings"]
        tab.tap()
        let row = app.descendants(matching: .any)["settings.kaku"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        let field = app.textFields["kaku.url"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(url)
        let tokenField = app.secureTextFields["kaku.token"].firstMatch
        tokenField.tap()
        tokenField.typeText(token)
        app.buttons["kaku.test"].firstMatch.tap()
        let connection = app.descendants(matching: .any)["kaku.connection"].firstMatch
        XCTAssertTrue(app.staticTexts["Now Transcribing"].waitForExistence(timeout: 20), "connected")
        for _ in 0..<6 where !(connection.exists && connection.isHittable) { app.swipeUp() }
        connection.tap()
        XCTAssertTrue(app.textFields["kaku.url"].waitForExistence(timeout: 5), "Connection, two screens deep")
        // iOS offers to save the token as a password: a system sheet over the app that takes the
        // taps until it has gone. That's what swallowed the re-tap in #166's run, not the app.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for source in [app, springboard] where source.buttons["Not Now"].waitForExistence(timeout: 3) {
            let notNow = source.buttons["Not Now"]
            notNow.tap()
            XCTAssertTrue(notNow.waitForNonExistence(timeout: 5))
            sleep(1)   // its closing animation still takes a tap
            break
        }
        tab.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5), "the top of Settings")
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(app.staticTexts["Now Transcribing"].waitForExistence(timeout: 10), "the next tap opens Kaku")
    }
}

/// Listen's stack is driven by a path of its own (`ListenView.reset`): two screens deep (Library
/// ▸ a show), tapping Listen again shows its top, and the next tap opens Library. Needs Kiku
/// signed in to Audiobookshelf on the simulator (`DevSetup`); skipped otherwise.
final class ListenRetapUITests: XCTestCase {
    @MainActor
    func testListenTabReturnsToTheTopFromTwoScreensDeep() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        let library = app.buttons["listen.library"].firstMatch
        guard library.waitForExistence(timeout: 20) else { throw XCTSkip("Sign Kiku in to Audiobookshelf on the simulator (DevSetup).") }
        library.tap()
        let show = app.buttons["library.show"].firstMatch
        XCTAssertTrue(show.waitForExistence(timeout: 20), "the library's shows")
        show.tap()
        XCTAssertTrue(show.waitForNonExistence(timeout: 10), "a show, two screens deep")
        sleep(1)
        app.tabBars.buttons["Listen"].tap()
        XCTAssertTrue(library.waitForExistence(timeout: 5) && library.isHittable, "the top of Listen")
        library.tap()
        XCTAssertTrue(show.waitForExistence(timeout: 20), "the next tap opens Library")
    }

    /// Side by side (an iPhone sideways, the Duo open), Library opens on the right and the
    /// Listen screen on the left stays where it is (it slid out and back). Needs DevSetup too.
    @MainActor
    func testWideListenStaysPutWhenOpeningLibrary() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let library = app.buttons["listen.library"].firstMatch
        guard library.waitForExistence(timeout: 20) else { throw XCTSkip("Sign Kiku in to Audiobookshelf on the simulator (DevSetup).") }
        sleep(1)
        library.tap()
        XCTAssertTrue(app.buttons["library.show"].firstMatch.waitForExistence(timeout: 20), "Library on the right")
        XCTAssertTrue(library.isHittable, "Listen still on the left")
        let pushes = app.descendants(matching: .any)["split.leftPushes"].firstMatch
        XCTAssertTrue(pushes.exists, "side by side, in a debug build")
        XCTAssertEqual(pushes.value as? String, "0", "Listen slid out and back")
    }

    /// Up Next on the test account (DevSetup): two episodes from a show's menu, Play Last then
    /// Play Next, show on Listen in that order; Edit, then Clear. The queue goes to
    /// Audiobookshelf's "Up Next" playlist, which Clear empties (Audiobookshelf then deletes it).
    @MainActor
    func testUpNextFromEpisodeMenus() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        let library = app.buttons["listen.library"].firstMatch
        guard library.waitForExistence(timeout: 20) else { throw XCTSkip("Sign Kiku in to Audiobookshelf on the simulator (DevSetup).") }
        library.tap()
        let show = app.buttons["library.show"].firstMatch
        XCTAssertTrue(show.waitForExistence(timeout: 20))
        show.tap()
        let episodes = app.buttons.matching(identifier: "show.episode")
        XCTAssertTrue(episodes.element(boundBy: 1).waitForExistence(timeout: 20), "two episodes")
        let first = episodes.element(boundBy: 0).label, second = episodes.element(boundBy: 1).label
        episodes.element(boundBy: 0).press(forDuration: 1.2)
        app.buttons["episode.playLast"].firstMatch.tap()
        episodes.element(boundBy: 1).press(forDuration: 1.2)
        app.buttons["episode.playNext"].firstMatch.tap()

        app.tabBars.buttons["Listen"].tap()
        app.tabBars.buttons["Listen"].tap()
        let items = app.descendants(matching: .any).matching(identifier: "upNext.item")
        XCTAssertTrue(items.element(boundBy: 1).waitForExistence(timeout: 10), "Up Next on Listen")
        // The second, played next, comes first.
        XCTAssertTrue(second.contains(items.element(boundBy: 0).label.components(separatedBy: ",").first ?? "~")
                      || items.element(boundBy: 0).label.contains(second.components(separatedBy: ",").first ?? "~"),
                      "\(items.element(boundBy: 0).label) vs \(second)")
        _ = first
        // On the server (when the test account is given): the "Up Next" playlist, two episodes.
        let server = UpNextServerCheck()
        if ProcessInfo.processInfo.environment["UITEST_ABS_URL"] != nil { XCTAssertNotNil(server, "signed in to check the server") }
        if let server { XCTAssertTrue(server.waitFor { $0 == [2] }, "Audiobookshelf's Up Next: \(server.counts() ?? [])") }
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "up-next"
        attachment.lifetime = .keepAlways
        add(attachment)

        app.buttons["upNext.edit"].firstMatch.tap()
        let clear = app.buttons["upNext.clear"].firstMatch
        XCTAssertTrue(clear.waitForExistence(timeout: 5))
        clear.tap()
        app.buttons["Clear Up Next"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Nothing Up Next"].waitForExistence(timeout: 5))
        if let server { XCTAssertTrue(server.waitFor { $0.isEmpty }, "cleared on the server too: \(server.counts() ?? [])") }
    }
}

/// Reads the test account's playlists on Audiobookshelf (`UITEST_ABS_URL/USER/PASSWORD`), for
/// checking what the outbox sent. Nil without them.
struct UpNextServerCheck {
    let base: URL
    let token: String

    init?() {
        let env = ProcessInfo.processInfo.environment
        guard let url = env["UITEST_ABS_URL"].flatMap(URL.init(string:)), let user = env["UITEST_ABS_USER"],
              let password = env["UITEST_ABS_PASSWORD"] else { return nil }
        var request = URLRequest(url: url.appending(path: "login"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["username": user, "password": password])
        guard let data = Self.load(request), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = (object["user"] as? [String: Any])?["token"] as? String else { return nil }
        base = url
        self.token = token
    }

    /// The item counts of the playlists named "Up Next".
    func counts() -> [Int]? {
        var request = URLRequest(url: base.appending(path: "api/playlists"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let data = Self.load(request), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let lists = object["playlists"] as? [[String: Any]] else { return nil }
        return lists.filter { $0["name"] as? String == "Up Next" }.map { ($0["items"] as? [Any])?.count ?? 0 }
    }

    func waitFor(_ test: ([Int]) -> Bool) -> Bool {
        for _ in 0..<20 {
            if let counts = counts(), test(counts) { return true }
            Thread.sleep(forTimeInterval: 1)
        }
        return false
    }

    private static func load(_ request: URLRequest) -> Data? {
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: Data?
        URLSession.shared.dataTask(with: request) { data, _, _ in result = data; done.signal() }.resume()
        done.wait()
        return result
    }
}
