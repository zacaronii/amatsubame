import Core
import Dictionary
import Foundation
@testable import Lookup
import Testing

/// Writes real lookups' glossaries with our compact summary of each, so the port can be checked
/// against Hachidori's own JavaScript. Skipped unless both are set:
/// `REAL_DICTIONARY_ZIPS="<zip>|…" COMPACT_SUMMARY_DUMP=<file.json> swift test --filter RealCompactSummaryTests`.
@Suite struct RealCompactSummaryTests {
    static let words = ["罪なき", "食べる", "猫", "何で", "見る", "日本語", "町に", "行く", "する", "いい", "ある", "取る", "かける",
                        "生", "上", "下", "手", "目", "気", "方", "事", "物", "大丈夫", "やばい", "すごい", "可愛い", "勉強", "先生",
                        "電車", "東京", "走る", "書く", "読む", "話す", "聞く", "思う", "言う", "出る", "入る", "立つ", "持つ"]

    @Test func dumpSummaries() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let zips = env["REAL_DICTIONARY_ZIPS"], let dump = env["COMPACT_SUMMARY_DUMP"] else { return }
        let database = try AppDatabase.inMemory()
        let library = DictionaryLibrary(database: database, directory: FileManager.default.temporaryDirectory.appending(path: "summary-\(UUID())"))
        for path in zips.split(separator: "|") { try await library.importDictionary(at: URL(filePath: String(path))) }
        try await library.reloadEngine()
        var cases: [[String: Any]] = []
        for word in Self.words {
            for result in await library.engine.lookup(word).prefix(3) {
                let glossaries = result.glossaries.map { ["dictionary": $0.dictionary, "glossary": $0.json] }
                for count in [1, 3, 6] {
                    let summary = CompactDefinitionSummary.extract(result.glossaries, maximumItems: count)
                    cases.append(["word": result.expression, "count": count, "glossaries": glossaries,
                                  "summary": summary.map { ["dictionary": $0.dictionary, "items": $0.items, "image": $0.imagePath as Any] } ?? NSNull()])
                }
            }
        }
        try JSONSerialization.data(withJSONObject: cases, options: [.prettyPrinted]).write(to: URL(filePath: dump))
    }
}
