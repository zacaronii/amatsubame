import DictionaryTestSupport
import XCTest

/// Search and tap-lookup in the simulator. Imports the dictionaries in
/// `UITEST_DICTIONARY_ZIPS` ("|"-separated paths, e.g. the real Jitendex, JPDB and
/// Kanjium zips in the gitignored Dictionaries/ folder); otherwise builds a tiny one.
final class DictionaryUITests: XCTestCase {
    private var app: XCUIApplication!
    private var usesRealDictionaries = false

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        var zips = ProcessInfo.processInfo.environment["UITEST_DICTIONARY_ZIPS"] ?? ""
        usesRealDictionaries = !zips.isEmpty
        if zips.isEmpty {
            var builder = TestDictionaryBuilder(title: "UITest Terms")
            builder.terms = [
                .init("食べる", "たべる", rules: "v1", glossary: ["to eat"]),
                .init("映画", "えいが", glossary: ["movie; film"]),
                .init("見る", "みる", rules: "v1", glossary: ["to see"]),
            ]
            var frequency = TestDictionaryBuilder(title: "UITest Freq")
            frequency.frequencies = [("食べる", "たべる", 184, nil)]
            var pitch = TestDictionaryBuilder(title: "UITest Pitch")
            pitch.pitches = [("食べる", "たべる", [2])]
            zips = try [builder, frequency, pitch].map { try $0.write().path(percentEncoded: false) }.joined(separator: "|")
        }
        app.launchEnvironment["UITEST_DICTIONARY_ZIPS"] = zips
    }

    func testSearchShowsDeinflectedWordWithFrequencyAndPitch() throws {
        app.launch()
        app.tabBars.buttons["Dictionary"].firstMatch.tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("食べさせられなかった")

        let results = app.webViews.firstMatch
        XCTAssertTrue(results.waitForExistence(timeout: 20))
        XCTAssertTrue(results.staticTexts["causative"].waitForExistence(timeout: 20), "deinflection trace shown")
        XCTAssertTrue(results.staticTexts.matching(NSPredicate(format: "label CONTAINS 'べる'")).firstMatch.exists, "headword 食べる shown")
        XCTAssertTrue(results.staticTexts["[2]"].exists, "pitch accent shown")
        if !usesRealDictionaries {
            XCTAssertTrue(results.staticTexts.matching(NSPredicate(format: "label CONTAINS '184'")).firstMatch.exists, "frequency shown")
        }
        if usesRealDictionaries {
            XCTAssertTrue(results.staticTexts.matching(NSPredicate(format: "label CONTAINS 'to eat'")).firstMatch.exists)
        }
        snapshot("search-tabesaserarenakatta")
    }

    func testTappingAWordInASentenceLooksItUp() throws {
        app.launch()
        app.tabBars.buttons["Dictionary"].firstMatch.tap()
        app.buttons["Sentence"].tap()
        let editor = app.textViews["search.sentenceEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.tap()
        editor.typeText("昨日映画を見た")
        app.buttons["search.sentenceDone"].tap()

        let text = app.webViews.staticTexts["昨日映画を見た"].firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 10))
        // 映 is the third of seven characters.
        text.coordinate(withNormalizedOffset: CGVector(dx: 2.5 / 7, dy: 0.5)).tap()
        let popup = app.webViews.element(boundBy: 1)
        XCTAssertTrue(popup.waitForExistence(timeout: 10), "lookup sheet opened")
        XCTAssertTrue(popup.staticTexts.matching(NSPredicate(format: "label CONTAINS 'movie' OR label CONTAINS 'film'")).firstMatch
            .waitForExistence(timeout: 10), "映画 looked up")
        snapshot("sentence-tap-eiga")
    }

    func testTappingInsideADefinitionOpensItAndBackReturns() throws {
        try XCTSkipUnless(usesRealDictionaries, "Needs Jitendex's example sentences.")
        app.launch()
        app.tabBars.buttons["Dictionary"].firstMatch.tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("映画\n")

        let results = app.webViews.firstMatch
        // Jitendex's example for 映画: その映画をもう一度見たいな。 Each kanji with furigana is its own
        // accessibility element; tap 見 (見たい → 見る).
        let miru = results.staticTexts["見"].firstMatch
        XCTAssertTrue(miru.waitForExistence(timeout: 20))
        miru.tap()

        let back = app.buttons["Back"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 10), "a new page was pushed")
        XCTAssertTrue(app.webViews.firstMatch.staticTexts.matching(NSPredicate(format: "label CONTAINS 'to see'")).firstMatch
            .waitForExistence(timeout: 10), "見る looked up from inside the definition")
        snapshot("recursive-miru")
        back.tap()
        XCTAssertTrue(app.webViews.firstMatch.staticTexts["movie"].waitForExistence(timeout: 10), "back to 映画")
    }

    func testAudioButtonFindsAudio() throws {
        try XCTSkipUnless(usesRealDictionaries, "Uses the default JapanesePod101 source over the network.")
        app.launch()
        app.tabBars.buttons["Dictionary"].firstMatch.tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("食べる\n")
        let play = app.webViews.firstMatch.buttons["Play audio"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 20))
        play.tap()
        let noAudio = app.staticTexts["No audio"]
        XCTAssertFalse(noAudio.waitForExistence(timeout: 8), "JapanesePod101 should have 食べる")
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The Stats tab with a few days of seeded reading (a screenshot to check by eye).
    func testStatsTab() throws {
        let app = XCUIApplication()
        app.launchEnvironment["UITEST_STATS"] = "1"
        app.launch()
        app.tabBars.buttons["Stats"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["stats.streak"].waitForExistence(timeout: 10), "streak shown")
        XCTAssertTrue(app.descendants(matching: .any)["stats.series"].firstMatch.exists, "by series")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "stats"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
