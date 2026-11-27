import XCTest

/// Picture in picture with a real Jellyfin transcode (an MKV with FLAC: AVPlayer can't take the
/// file, so Jellyfin converts it), and Miru put away while it plays, as it's used. The stream
/// must keep going: Jellyfin still transcoding for Miru half a minute later. Live: needs Miru
/// signed in to a test account on an iPad simulator (`DevSetup`, docs/shared.md),
/// `TEST_RUNNER_UITEST_SEARCH_QUERY` (finds a show whose first episode is such a file) and the
/// account in `.env` (`JELLYFIN_URL`, `TEST_JELLYFIN_*`), to ask Jellyfin.
final class PictureInPictureLiveUITests: XCTestCase {
    func testTheStreamKeepsGoingWithMiruPutAway() throws {
        guard let query = ProcessInfo.processInfo.environment["UITEST_SEARCH_QUERY"] else {
            throw XCTSkip("Set TEST_RUNNER_UITEST_SEARCH_QUERY.")
        }
        let account = try TestAccounts.require("JELLYFIN_URL", "TEST_JELLYFIN_USER", "TEST_JELLYFIN_PASSWORD")
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["UITEST_MUTE"] = "1"
        app.launchEnvironment["UITEST_PLAYER_PIP"] = "4"
        app.launch()
        let search = app.buttons["watch.search"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 20), "signed in to Jellyfin")
        search.tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText(query)
        let result = app.descendants(matching: .any)["search.result"].firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 15), "something found")
        result.tap()
        let play = app.descendants(matching: .any)["series.play"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 15), "the show's page")
        play.tap()
        let playing = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Playing in Picture in Picture'")).firstMatch
        XCTAssertTrue(playing.waitForExistence(timeout: 90), "handed to picture in picture")
        attach(XCUIScreen.main.screenshot(), "picture in picture")

        // Put away, as it's used: Home, and the small window plays on.
        XCUIDevice.shared.press(.home)
        sleep(35)
        attach(XCUIScreen.main.screenshot(), "home, 35 s on")
        let sessions = try JellyfinCheck(url: account[0], user: account[1], password: account[2]).miruSessions()
        XCTAssertTrue(sessions.contains { $0.transcoding && $0.playing }, "Jellyfin still transcoding for Miru: \(sessions)")

        app.activate()
        let back = app.buttons.matching(NSPredicate(format: "label == 'Back Here'")).firstMatch
        if back.waitForExistence(timeout: 10) { back.tap() }
        XCTAssertTrue(playing.waitForNonExistence(timeout: 10), "back to the player")
        app.buttons["player.close"].firstMatch.tap()
    }

    private func attach(_ screenshot: XCUIScreenshot, _ name: String) {
        let shot = XCTAttachment(screenshot: screenshot)
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}

/// Asks Jellyfin (as the test account, its own short session, signed out after) what Miru's
/// sessions are doing.
struct JellyfinCheck {
    struct Session: CustomStringConvertible {
        var playing: Bool
        var transcoding: Bool
        var description: String { "playing \(playing), transcoding \(transcoding)" }
    }

    let url: String
    let user: String
    let password: String
    let device = "check-\(UUID().uuidString.prefix(8))"

    func miruSessions() throws -> [Session] {
        let auth = "MediaBrowser Client=\"Amatsubame Check\", Device=\"Check\", DeviceId=\"\(device)\", Version=\"0\""
        let login = try send("POST", "Users/AuthenticateByName", auth: auth, body: ["Username": user, "Pw": password])
        guard let token = login["AccessToken"] as? String else { throw XCTSkip("Couldn't sign in to check.") }
        defer { _ = try? send("POST", "Sessions/Logout", auth: auth + ", Token=\"\(token)\"") }
        let sessions = try sendArray("GET", "Sessions", auth: auth + ", Token=\"\(token)\"")
        return sessions.filter { ($0["Client"] as? String)?.contains("Miru") == true }.map { session in
            Session(playing: session["NowPlayingItem"] != nil, transcoding: session["TranscodingInfo"] != nil)
        }
    }

    private func request(_ method: String, _ path: String, auth: String, body: [String: Any]?) throws -> Data {
        var request = URLRequest(url: URL(string: url)!.appending(path: path))
        request.httpMethod = method
        request.setValue(auth, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let done = DispatchSemaphore(value: 0)
        var result: Data?
        URLSession.shared.dataTask(with: request) { data, _, _ in
            result = data
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 30)
        return result ?? Data()
    }

    private func send(_ method: String, _ path: String, auth: String, body: [String: Any]? = nil) throws -> [String: Any] {
        let data = try request(method, path, auth: auth, body: body)
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private func sendArray(_ method: String, _ path: String, auth: String) throws -> [[String: Any]] {
        let data = try request(method, path, auth: auth, body: nil)
        return (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
    }
}
