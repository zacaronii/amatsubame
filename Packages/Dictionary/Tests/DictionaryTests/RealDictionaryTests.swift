import Dictionary
import Foundation
import Testing

/// Runs against real dictionaries when `REAL_DICTIONARY_ZIPS` lists them
/// ("|"-separated paths, e.g. the gitignored Dictionaries/ folder); skipped otherwise.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["REAL_DICTIONARY_ZIPS"] != nil))
struct RealDictionaryTests {
    static func importedLibrary() async throws -> DictionaryLibrary {
        let library = try makeLibrary()
        for path in ProcessInfo.processInfo.environment["REAL_DICTIONARY_ZIPS"]!.split(separator: "|") {
            let outcome = try await library.importDictionary(at: URL(filePath: String(path)))
            print("Imported \(outcome.dictionary.title) in \(String(format: "%.2f", outcome.seconds))s, \(outcome.dictionary.bytes / 1_000_000) MB")
        }
        return library
    }

    @Test func phaseTwoDoneCriterion() async throws {
        let library = try await Self.importedLibrary()
        let result = try #require(await library.engine.lookup("食べさせられなかった").first)
        #expect(result.expression == "食べる")
        #expect(result.inflections.map(\.name) == ["causative", "potential or passive", "negative", "-た"])
        #expect(result.glossaries.contains { $0.dictionary.hasPrefix("Jitendex") })
        #expect(!result.frequencies.isEmpty, "JPDB frequency")
        #expect(result.pitches.first?.accents.first?.downstep == 2, "Kanjium pitch")
    }

    /// With JMnedict in `REAL_DICTIONARY_ZIPS`: tapping た in 「たと思う」 opens た, not the name タト,
    /// while 「まさと」 typed in Search still finds the name first.
    @Test func convertedNamesRankBelowWordsInText() async throws {
        let library = try await Self.importedLibrary()
        let tapped = NameRanking.forTextTap(await library.engine.lookup("たと思う"))
        let searched = await library.engine.lookup("まさと")
        guard searched.first?.glossaries.first?.dictionary.hasPrefix("JMnedict") == true else { return }  // no JMnedict
        #expect(tapped.first?.matched == "た")
        #expect(searched.first?.expression == "マサト")
    }

    /// Word marks split a chapter in the background: report how long one takes.
    @Test func chapterScanSpeed() async throws {
        let library = try await Self.importedLibrary()
        let paragraph = "朝から雨が降っていたので、駅前の小さな喫茶店で本を読むことにした。窓際の席に座ると、店主が温かいコーヒーを出してくれた。久しぶりに時間を忘れて、三冊目の最後のページまで読み終えた。"
        let chapter = String(repeating: paragraph, count: 50)
        let started = ContinuousClock.now
        let words = await library.scanner.words(in: chapter)
        let elapsed = ContinuousClock.now - started
        print("Scanned \(chapter.count) characters into \(words.count) words in \(elapsed)")
        #expect(words.count > 500)
        #expect(elapsed < .seconds(20))
    }

    @Test func lookupSpeed() async throws {
        let library = try await Self.importedLibrary()
        let text = "昨日、友達と一緒に新しい映画を見に行ったけど、思ったより面白くなかったので途中で帰ってしまった。"
        let starts = Array(text.indices)
        var times: [Double] = []
        for round in 0..<200 {
            let scan = String(text[starts[round % starts.count]...].prefix(16))
            let started = ContinuousClock.now
            _ = await library.engine.lookup(scan)
            let elapsed = ContinuousClock.now - started
            times.append(Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000)
        }
        times.sort()
        let median = times[times.count / 2], p95 = times[times.count * 95 / 100]
        print("200 lookups: median \(String(format: "%.2f", median)) ms, p95 \(String(format: "%.2f", p95)) ms, max \(String(format: "%.2f", times.last!)) ms")
        #expect(median < 20)
    }
}
