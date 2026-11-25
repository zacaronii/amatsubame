import XCTest

/// Try It with the Demo Servers (public beta).
final class DemoUITests: XCTestCase {
    func testDemoButtonWithoutTheDemo() {
        checkDemoButton(XCUIApplication.setup(data: "miru-demo-\(UUID().uuidString.prefix(8))"), server: "Connect Jellyfin")
    }

    func testDemoSignsIn() throws {
        try checkDemoSignIn(XCUIApplication.setup(data: "miru-demo-\(UUID().uuidString.prefix(8))"), server: "Connect Jellyfin")
    }
}
