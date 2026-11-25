import XCTest

/// Settings ▸ Anki's key field: a saved key shows as dots, and only a server with no key saved
/// says "No API key saved" (screenshots hide a secure field's dots, which looked like no key).
/// In memory; the server address is unreachable and nothing is sent.
final class AnkiSettingsUITests: XCTestCase {
    private func keyField(savedKey: String?) -> XCUIElement {
        let app = XCUIApplication()
        app.launchEnvironment["UITEST_STATS"] = "1"
        app.launchEnvironment["UITEST_ANKI_URL"] = "http://127.0.0.1:9"
        if let savedKey { app.launchEnvironment["UITEST_ANKI_KEY"] = savedKey }
        app.launch()
        let settings = app.buttons["Settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 20))
        settings.tap()
        let anki = app.descendants(matching: .any)["settings.anki"].firstMatch
        for _ in 0..<6 where !(anki.exists && anki.isHittable) { app.swipeUp() }
        XCTAssertTrue(anki.waitForExistence(timeout: 10))
        anki.tap()
        let field = app.secureTextFields["anki.key"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        return field
    }

    func testASavedKeyShowsAsDots() {
        let field = keyField(savedKey: "made-up-key")
        let value = field.value as? String ?? ""
        XCTAssertEqual(value.count, "made-up-key".count, "one dot per character")
        XCTAssertFalse(value.contains("made-up"), "never the key itself")
    }

    func testNoSavedKeySaysSo() {
        let field = keyField(savedKey: nil)
        XCTAssertEqual(field.placeholderValue, "No API key saved")
        XCTAssertTrue((field.value as? String ?? "").isEmpty || field.value as? String == "No API key saved")
    }
}
