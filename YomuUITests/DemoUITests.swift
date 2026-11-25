import XCTest

/// Try It with the Demo Servers (public beta).
final class DemoUITests: XCTestCase {
    func testDemoButtonWithoutTheDemo() {
        checkDemoButton(XCUIApplication.setup(data: "yomu-demo-\(UUID().uuidString.prefix(8))"), server: "Connect Kavita")
    }

    func testDemoSignsIn() throws {
        try checkDemoSignIn(XCUIApplication.setup(data: "yomu-demo-\(UUID().uuidString.prefix(8))"), server: "Connect Kavita")
    }
}
