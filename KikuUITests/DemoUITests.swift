import XCTest

/// Try It with the Demo Servers (public beta).
final class DemoUITests: XCTestCase {
    func testDemoButtonWithoutTheDemo() {
        checkDemoButton(XCUIApplication.setup(data: "kiku-demo-\(UUID().uuidString.prefix(8))"), server: "Connect Audiobookshelf")
    }

    func testDemoSignsIn() throws {
        try checkDemoSignIn(XCUIApplication.setup(data: "kiku-demo-\(UUID().uuidString.prefix(8))"), server: "Connect Audiobookshelf")
    }
}
