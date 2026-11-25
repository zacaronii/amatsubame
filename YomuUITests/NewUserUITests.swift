import XCTest

/// What a newcomer sees (public beta): no server at all, and Kavita alone (the demo server,
/// `DEMO_SERVER_*` in `.env`) with nothing else. Screenshots of every step and tab are kept in
/// the result to review; run on a simulator where no other Amatsubame app is installed.
final class NewUserUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    func testNoServerAtAll() {
        let app = XCUIApplication.setup(data: "yomu-new-\(UUID().uuidString.prefix(8))")
        app.launch()
        skipSetup(app, prefix: "none")
        tourTabs(app, prefix: "none")
        searchDictionary(app, prefix: "none")
    }

    func testKavitaAlone() throws {
        let v = try TestAccounts.require("DEMO_SERVER_KAVITA_URL", "DEMO_SERVER_KAVITA_KEY")
        let app = XCUIApplication.setup(data: "yomu-alone-\(UUID().uuidString.prefix(8))")
        app.launch()
        setUpWithOneServer(app, prefix: "alone", server: "Connect Kavita", fields: [("setup.server.url", v[0]), ("setup.server.key", v[1])])
        tourTabs(app, prefix: "alone")
        searchDictionary(app, prefix: "alone")
    }
}
