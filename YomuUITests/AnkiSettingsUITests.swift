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

    /// The Anki row follows a deck changed on its page (it read the settings once and kept the
    /// old deck). Live: the test AnkiConnect's deck list (`HACHIDORI_ANKICONNECT_*` in `.env`);
    /// only this app's own setting changes, and no card is sent.
    func testTheRowFollowsANewDeck() throws {
        let v = try TestAccounts.require("HACHIDORI_ANKICONNECT_URL", "HACHIDORI_ANKICONNECT_KEY")
        let app = XCUIApplication()
        app.launchEnvironment["UITEST_STATS"] = "1"
        app.launchEnvironment["UITEST_ANKI_URL"] = v[0]
        app.launchEnvironment["UITEST_ANKI_KEY"] = v[1]
        app.launch()
        let settings = app.buttons["Settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 20))
        settings.tap()
        let anki = app.descendants(matching: .any)["settings.anki"].firstMatch
        for _ in 0..<6 where !(anki.exists && anki.isHittable) { app.swipeUp() }
        XCTAssertTrue(anki.waitForExistence(timeout: 10))
        anki.tap()
        let deck = app.buttons["anki.deck"].firstMatch
        for _ in 0..<4 where !(deck.exists && deck.isHittable) { app.swipeUp() }
        XCTAssertTrue(deck.waitForExistence(timeout: 20), "the Deck picker (Anki answered)")
        let before = deck.value as? String ?? ""
        deck.tap()
        // The menu: any deck other than the current one.
        let choices = app.buttons.allElementsBoundByIndex.filter { $0.isHittable && !$0.label.isEmpty && $0.label != before
            && !["Back", "Settings", "Anki"].contains($0.label) && $0.identifier.isEmpty }
        let other = try XCTUnwrap(choices.first, "another deck to pick")
        let picked = other.label
        other.tap()
        sleep(1)
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(anki.waitForExistence(timeout: 10))
        sleep(1)
        XCTAssertTrue(anki.label.contains("Deck: \(picked)"), "the row shows \(picked): \(anki.label)")
    }
}
