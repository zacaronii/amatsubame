import XCTest

/// What a newcomer sees (public beta): no server at all, and Audiobookshelf alone (the demo server,
/// their published config.json) with nothing else. Screenshots of every step and tab are kept in
/// the result to review; run on a simulator where no other Amatsubame app is installed.
final class NewUserUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    func testNoServerAtAll() {
        let app = XCUIApplication.setup(data: "kiku-new-\(UUID().uuidString.prefix(8))")
        app.launch()
        skipSetup(app, prefix: "none")
        tourTabs(app, prefix: "none")
        searchDictionary(app, prefix: "none")
    }

    func testAudiobookshelfAlone() throws {
        let v = try DemoServers.audiobookshelf()
        let app = XCUIApplication.setup(data: "kiku-alone-\(UUID().uuidString.prefix(8))")
        app.launch()
        setUpWithOneServer(app, prefix: "alone", server: "Connect Audiobookshelf", fields: [("setup.server.url", v[0]), ("setup.server.username", v[1]), ("setup.server.password", v[2])])
        tourTabs(app, prefix: "alone")
        searchDictionary(app, prefix: "alone")
    }
}
