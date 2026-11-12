import Dictionary
import DictionaryTestSupport
import Foundation
import Testing

@Suite struct WordScannerTests {
    static func scanner() async throws -> WordScanner {
        var builder = TestDictionaryBuilder(title: "Words")
        builder.terms = [
            .init("悪い", "わるい", rules: "adj-i"), .init("思う", "おもう", rules: "v5"), .init("思ったより", "おもったより"),
            .init("ゲーム", "げーむ"), .init("お茶", "おちゃ"), .init("茶", "ちゃ"), .init("飲む", "のむ", rules: "v5"),
            .init("は", "は"), .init("より", "より"), .init("時間", "じかん"), .init("時", "とき"),
        ]
        let library = try makeLibrary()
        try await library.importDictionary(at: try builder.write())
        return library.scanner
    }

    @Test func findsWordsByTheirDictionaryForm() async throws {
        let text = "思ったより悪くなかった。ゲーム時間はお茶を飲んだ"
        let words = try await Self.scanner().words(in: text)
        let utf16 = Array(text.utf16)
        let found = words.map { (String(utf16Units: utf16[$0.offset..<$0.offset + $0.length]), $0.expression) }
        #expect(found.map(\.0) == ["思ったより", "悪くなかった", "ゲーム", "時間", "お茶", "飲んだ"])
        #expect(found.map(\.1) == ["思ったより", "悪い", "ゲーム", "時間", "お茶", "飲む"])
    }

    @Test func kanaOnlyWordsAndOtherTextAreSkipped() async throws {
        let words = try await Self.scanner().words(in: "より、はは。Hello 😀 ゲ")
        #expect(words.isEmpty)
    }
}

extension String {
    init(utf16Units: ArraySlice<UInt16>) {
        self = String(decoding: utf16Units, as: UTF16.self)
    }
}
