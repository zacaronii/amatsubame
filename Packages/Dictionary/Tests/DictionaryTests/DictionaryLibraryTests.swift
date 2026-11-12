import Core
import Dictionary
import DictionaryTestSupport
import Foundation
import Testing

@Suite struct DictionaryLibraryTests {
    func termDictionary(_ title: String, revision: String = "1", gloss: String = "to eat") -> TestDictionaryBuilder {
        var builder = TestDictionaryBuilder(title: title, revision: revision)
        builder.terms = [.init("食べる", "たべる", rules: "v1", glossary: [gloss], definitionTags: "v1 ★")]
        return builder
    }

    @Test func importRecordsKindsCountsAndLoadsEngine() async throws {
        let library = try makeLibrary()
        let outcome = try await library.importDictionary(at: try termDictionary("Terms").write())
        let record = outcome.dictionary
        #expect(record.title == "Terms")
        #expect(record.revision == "1")
        #expect(record.hasTerms && !record.hasFrequencies && !record.hasPitches)
        #expect(record.termCount == 1)
        #expect(record.bytes > 0)
        #expect(!outcome.replacedPrevious)
        #expect(FileManager.default.fileExists(atPath: library.folder(for: record).appending(path: "index.json").path()))

        let result = try #require(await library.engine.lookup("食べた").first)
        #expect(result.expression == "食べる")
        #expect(result.reading == "たべる")
        #expect(result.glossaries.first?.json == #"["to eat"]"#)
        #expect(result.glossaries.first?.definitionTags == ["v1", "★"])
        #expect(result.inflections.map(\.name) == ["-た"])
    }

    @Test func sameRevisionIsRejectedNewerReplacesInPlace() async throws {
        let library = try makeLibrary()
        let first = try await library.importDictionary(at: try termDictionary("Terms", revision: "1").write()).dictionary
        try await library.setEnabled(first.id, false)

        await #expect(throws: DictionaryError.alreadyInstalled(title: "Terms", revision: "1")) {
            try await library.importDictionary(at: try termDictionary("Terms", revision: "1").write())
        }
        let second = try await library.importDictionary(at: try termDictionary("Terms", revision: "2", gloss: "new").write())
        #expect(second.replacedPrevious)
        #expect(try library.dictionaries().map(\.revision) == ["2"])
        #expect(second.dictionary.enabled == false, "keeps the user's enabled state")
        #expect(!FileManager.default.fileExists(atPath: library.folder(for: first).path()))
    }

    @Test func anUpdateUnderANewTitleKeepsTheDictionary() async throws {
        let library = try makeLibrary()
        var first = TestDictionaryBuilder(title: "Freq [2026-10-03]", revision: "2026.10.03")
        first.frequencies = [("食べる", nil, 10, nil)]
        first.index = ["isUpdatable": true, "indexUrl": "https://example.com/index.json", "downloadUrl": "https://example.com/dict.zip"]
        let old = try await library.importDictionary(at: try first.write(), catalogId: "freq").dictionary
        let other = try await library.importDictionary(at: try termDictionary("Other").write()).dictionary
        try await library.reorder([other.id, old.id])
        try await library.setEnabled(old.id, false)
        try await library.setFrequencySortDictionary(old.title)

        var second = first
        second.title = "Freq [2026-11-01]"
        second.revision = "2026.11.01"
        let updated = try await library.importDictionary(at: try second.write(), replacing: old.id)
        #expect(updated.replacedPrevious)
        #expect(updated.dictionary.id == old.id, "keeps its id")
        #expect(try library.dictionaries().map(\.title) == ["Other", "Freq [2026-11-01]"], "keeps its place")
        #expect(updated.dictionary.enabled == false)
        #expect(try library.settings().frequencySortTitle == "Freq [2026-11-01]", "the frequency sort follows it")
        #expect(!FileManager.default.fileExists(atPath: library.folder(for: old).path()), "the old folder is gone")
        #expect(FileManager.default.fileExists(atPath: library.folder(for: updated.dictionary).path()))
        let source = try #require(try library.sources()[old.id])
        #expect(source.catalogId == "freq" && source.isUpdatable && source.indexUrl == "https://example.com/index.json")
        #expect(source.updates)
    }

    @Test func deletingARecommendedDictionaryIsRemembered() async throws {
        let library = try makeLibrary()
        let recommended = try await library.importDictionary(at: try termDictionary("Rec").write(), catalogId: "rec").dictionary
        let imported = try await library.importDictionary(at: try termDictionary("Mine").write()).dictionary
        #expect(try library.sources()[imported.id]?.updates == false, "imported, not updatable")
        try await library.delete(imported.id)
        try await library.delete(recommended.id)
        #expect(try library.settings().removedRecommended == ["rec"])
        #expect(try library.sources().isEmpty)
    }

    @Test func leftoverFoldersAreRemovedOnceStale() async throws {
        let library = try makeLibrary()
        let kept = try await library.importDictionary(at: try termDictionary("Kept").write()).dictionary
        let stray = library.directory.appending(path: "stray-folder")
        try FileManager.default.createDirectory(at: stray, withIntermediateDirectories: true)
        library.removeUnfinishedImports()
        #expect(FileManager.default.fileExists(atPath: stray.path()), "too new: another app may be installing it")
        library.removeUnfinishedImports(olderThan: 0)
        #expect(!FileManager.default.fileExists(atPath: stray.path()))
        #expect(FileManager.default.fileExists(atPath: library.folder(for: kept).path()))
    }

    @Test func badZipFailsAndLeavesNothingBehind() async throws {
        let library = try makeLibrary()
        let junk = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).zip")
        try Data("not a zip".utf8).write(to: junk)
        await #expect(throws: DictionaryError.self) { try await library.importDictionary(at: junk) }
        #expect(try library.dictionaries().isEmpty)
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: library.directory.path())) ?? []
        #expect(leftovers.isEmpty)
    }

    @Test func orderEnableAndDeleteControlResults() async throws {
        let library = try makeLibrary()
        let a = try await library.importDictionary(at: try termDictionary("A", gloss: "from A").write()).dictionary
        let b = try await library.importDictionary(at: try termDictionary("B", gloss: "from B").write()).dictionary

        func dictionaries() async -> [String] {
            await library.engine.lookup("食べる").first?.glossaries.map(\.dictionary) ?? []
        }
        #expect(await dictionaries() == ["A", "B"])
        try await library.reorder([b.id, a.id])
        #expect(await dictionaries() == ["B", "A"])
        try await library.setEnabled(b.id, false)
        #expect(await dictionaries() == ["A"])
        try await library.delete(a.id)
        #expect(await library.engine.lookup("食べる").isEmpty)
        #expect(try library.dictionaries().map(\.title) == ["B"])
    }

    @Test func frequencyPitchStylesAndMediaDecode() async throws {
        let library = try makeLibrary()
        var terms = termDictionary("Terms")
        terms.styles = "span { color: red; }"
        terms.media = ["img/a.svg": Data("<svg/>".utf8)]
        try await library.importDictionary(at: try terms.write())

        var frequency = TestDictionaryBuilder(title: "Freq")
        frequency.frequencies = [("食べる", "たべる", 184, nil), ("食べる", "たべる", 13390, "13390㋕")]
        try await library.importDictionary(at: try frequency.write())

        var pitch = TestDictionaryBuilder(title: "Pitch")
        pitch.pitches = [("食べる", "たべる", [2])]
        let pitchRecord = try await library.importDictionary(at: try pitch.write()).dictionary
        #expect(pitchRecord.hasPitches && !pitchRecord.hasTerms)

        let result = try #require(await library.engine.lookup("食べる").first)
        #expect(result.frequencies == [FrequencyGroup(dictionary: "Freq", values: [
            Frequency(value: 184, display: "184"), Frequency(value: 13390, display: "13390㋕"),
        ])])
        #expect(result.pitches.first?.accents.map(\.downstep) == [2])
        #expect(await library.engine.styles()["Terms"] == "span { color: red; }")
        #expect(await library.engine.mediaFile(dictionary: "Terms", path: "img/a.svg") == Data("<svg/>".utf8))
        #expect(await library.engine.mediaFile(dictionary: "Terms", path: "missing.png") == nil)
    }

    @Test func frequencySortSettingPicksDictionary() async throws {
        let library = try makeLibrary()
        try await library.importDictionary(at: try termDictionary("Terms").write())
        var frequency = TestDictionaryBuilder(title: "Freq")
        frequency.frequencies = [("食べる", nil, 10, nil)]
        try await library.importDictionary(at: try frequency.write())
        try await library.setFrequencySortDictionary("Freq")
        #expect(try library.settings().frequencySortTitle == "Freq")
        #expect(await library.engine.lookup("食べる").count == 1)
    }
}

@Suite struct TextLogicTests {
    @Test(arguments: [
        ("食べる", "たべる", [Furigana.Segment("食", "た"), Furigana.Segment("べる")]),
        ("見た目", "みため", [Furigana.Segment("見", "み"), Furigana.Segment("た"), Furigana.Segment("目", "め")]),
        ("日本語", "にほんご", [Furigana.Segment("日本語", "にほんご")]),
        ("お茶", "おちゃ", [Furigana.Segment("お"), Furigana.Segment("茶", "ちゃ")]),
        ("たべる", "たべる", [Furigana.Segment("たべる")]),
        ("コーヒー", "こーひー", [Furigana.Segment("コーヒー")]),
        ("取り扱い", "とりあつかい", [Furigana.Segment("取", "と"), Furigana.Segment("り"), Furigana.Segment("扱", "あつか"), Furigana.Segment("い")]),
    ])
    func furigana(expression: String, reading: String, expected: [Furigana.Segment]) {
        #expect(Furigana.segments(expression: expression, reading: reading) == expected)
    }

    @Test func unalignableReadingFallsBackToWholeWord() {
        #expect(Furigana.segments(expression: "食べる", reading: "くう") == [Furigana.Segment("食べる", "くう")])
    }

    @Test func moraSplitting() {
        #expect(Mora.split("きゃく") == ["きゃ", "く"])
        #expect(Mora.split("がっこう") == ["が", "っ", "こ", "う"])
        #expect(Mora.split("ジュース") == ["ジュ", "ー", "ス"])
    }

    @Test(arguments: [
        ("さくら", 0, [false, true, true, true], PitchGraph.Pattern.heiban),
        ("いのち", 1, [true, false, false, false], .atamadaka),
        ("たべる", 2, [false, true, false, false], .nakadaka),
        ("あたま", 3, [false, true, true, false], .odaka),
    ])
    func pitchGraph(reading: String, downstep: Int, highs: [Bool], pattern: PitchGraph.Pattern) {
        let graph = PitchGraph(reading: reading, downstep: downstep)
        #expect(graph.highs == highs)
        #expect(graph.pattern == pattern)
    }

    @Test func scanTextStartsAtTapAndStopsAtNewline() {
        let text = "昨日、友達と映画を見た。\nとても面白かった。"
        #expect(TextScanner.scanText(text, utf16Offset: 6) == "映画を見た。")
        #expect(TextScanner.scanText(text, utf16Offset: 0, maxLength: 4) == "昨日、友")
        #expect(TextScanner.scanText(text, utf16Offset: 999).isEmpty)
    }

    @Test func sentenceAroundTap() {
        let text = "彼は言った。「もう食べられないよ。」そして寝た。"
        #expect(TextScanner.sentence(in: text, utf16Offset: 9) == "「もう食べられないよ。」")
        #expect(TextScanner.sentence(in: text, utf16Offset: 1) == "彼は言った。")
        #expect(TextScanner.sentence(in: text, utf16Offset: 20) == "そして寝た。")
        #expect(TextScanner.sentence(in: "一行目\n二行目です", utf16Offset: 5) == "二行目です")
    }

    @Test func wholeTextSplitsLikeTheTap() {
        let text = "彼は言った。「もう食べられないよ。」そして寝た……！？\n 一行目\n\n二行目"
        let sentences = TextScanner.sentences(in: text).map { String(text.utf16[text.utf16.index(text.startIndex, offsetBy: $0.lowerBound)..<text.utf16.index(text.startIndex, offsetBy: $0.upperBound)])! }
        #expect(sentences == ["彼は言った。", "「もう食べられないよ。」", "そして寝た……！？", "一行目", "二行目"])
        #expect(TextScanner.sentences(in: "  ").isEmpty)
    }

    @Test func surrogatePairsAreHandled() {
        // 𠮟 is outside the BMP (two UTF-16 units).
        let text = "𠮟る"
        #expect(TextScanner.scanText(text, utf16Offset: 1) == "𠮟る")
        #expect(TextScanner.scanText(text, utf16Offset: 2) == "る")
    }
}
