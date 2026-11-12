import XCTest

/// For setup's UI tests: test accounts from the repo's gitignored `.env`
/// (`TEST_*`). Tests skip when it's missing.
enum TestAccounts {
    static let values: [String: String] = {
        // The simulator can read the Mac's files: the repo is two folders up from this one.
        let env = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: ".env")
        guard let text = try? String(contentsOf: env, encoding: .utf8) else { return [:] }
        var values: [String: String] = [:]
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            guard let equals = line.firstIndex(of: "=") else { continue }
            var value = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" {
                value = String(value.dropFirst().dropLast())
            }
            values[String(line[..<equals]).trimmingCharacters(in: .whitespaces)] = value
        }
        return values
    }()

    static func require(_ keys: String...) throws -> [String] {
        let found = keys.compactMap { values[$0].flatMap { $0.isEmpty ? nil : $0 } }
        guard found.count == keys.count else { throw XCTSkip("Needs \(keys.joined(separator: ", ")) in .env.") }
        return found
    }

    /// Two of the test account's libraries for checking setup's guess, from `key` in `.env` as
    /// `<Japanese-named library>|<English-named library>` (e.g. `TEST_KAVITA_LIBRARIES=漫画|Books`).
    static func libraries(_ key: String) throws -> (japanese: String, english: String) {
        let parts = (values[key] ?? "").split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty }) else {
            throw XCTSkip("Needs \(key)=<Japanese library>|<English library> in .env (two of the test account's libraries).")
        }
        return (parts[0], parts[1])
    }
}

extension XCUIApplication {
    /// A first launch with its own data set (`UITEST_SETUP_DATA`), the same set on relaunch.
    static func setup(_ bundleIdentifier: String? = nil, data: String) -> XCUIApplication {
        let app = bundleIdentifier.map(XCUIApplication.init(bundleIdentifier:)) ?? XCUIApplication()
        app.launchEnvironment["UITEST_SETUP_DATA"] = data
        return app
    }

    func element(_ identifier: String) -> XCUIElement {
        descendants(matching: .any)[identifier].firstMatch
    }

    func type(_ text: String, into identifier: String) {
        let field = element(identifier)
        XCTAssertTrue(field.waitForExistence(timeout: 10), "\(identifier) shows")
        field.tap()
        field.typeText(text)
    }

    /// iOS's "Save Password?" after a secure field, which covers the page.
    func dismissSavePassword() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for app in [springboard, self] where app.buttons["Not Now"].waitForExistence(timeout: 1) {
            app.buttons["Not Now"].tap()
        }
    }

    /// Taps the page's main button once it's enabled.
    func tapContinue(timeout: TimeInterval = 30) {
        dismissSavePassword()
        let button = buttons["setup.continue"]
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: button)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: timeout), .completed, "Continue is enabled")
        button.tap()
    }

    func waitForTitle(_ title: String, timeout: TimeInterval = 20) -> Bool {
        let label = staticTexts["setup.title"]
        let match = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", title), object: label)
        return XCTWaiter.wait(for: [match], timeout: timeout) == .completed
    }
}

enum SharedSetupFixture {
    /// Fills data set `data`'s shared setup from Yomu's DevSetup (a small dictionary), as if
    /// Yomu had been set up first; with no origin recorded. Skips when Yomu isn't installed.
    static func prepare(data: String, ankiURL: String? = nil, ankiKey: String? = nil) throws {
        let yomu = XCUIApplication.setup("com.amatsubame.yomu", data: data)
        let zip = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Dictionaries/kanjium_pitch_accents.zip")
        guard FileManager.default.fileExists(atPath: zip.path) else { throw XCTSkip("Needs Dictionaries/kanjium_pitch_accents.zip.") }
        yomu.launchEnvironment["DEV_SETUP"] = "1"
        yomu.launchEnvironment["DEV_IMPORT_DICTIONARIES"] = zip.path
        if let ankiURL { yomu.launchEnvironment["DEV_ANKI_URL"] = ankiURL }
        if let ankiKey { yomu.launchEnvironment["DEV_ANKI_KEY"] = ankiKey }
        yomu.launch()
        guard yomu.wait(for: .runningForeground, timeout: 15) else { throw XCTSkip("Needs Yomu installed on this simulator.") }
        // DevSetup imports in the background.
        sleep(12)
        yomu.terminate()
    }
}
