@testable import AppCommon
import Core
import CoreTestSupport
import Dictionary
import DictionaryTestSupport
import Foundation
import Lookup
import Testing

@MainActor @Suite struct LineLookupTests {
    func service() async throws -> LookupService {
        let library = DictionaryLibrary(database: try AppDatabase.inMemory(),
                                        directory: FileManager.default.temporaryDirectory.appending(path: "line-lookup-\(UUID().uuidString)"))
        var builder = TestDictionaryBuilder(title: "Words")
        builder.terms = [.init("罪", "つみ"), .init("無き", "なき"), .init("罪無き", "つみなき")]
        _ = try await library.importDictionary(at: try builder.write())
        return LookupService(library: library, audio: AudioService(database: library.database, http: HTTPClient(), secrets: InMemorySecretStore()))
    }

    /// The highlight follows the word the popup shows: taps in its sentence move it, Back
    /// moves it back, a word from a definition leaves it, and closing clears it.
    @Test func theHighlightFollowsThePopup() async throws {
        let service = try await service()
        let lines = LineLookup(service: service)
        lines.lookUp("その罪無き人", characterIndex: 3, key: "cue-1", context: nil)
        while lines.popup == nil { await Task.yield() }
        #expect(lines.highlight?.key == "cue-1")
        #expect(lines.highlightedRange(for: "cue-1") == 3..<5, "無き")
        #expect(lines.highlightedRange(for: "cue-2") == nil)

        // 罪無き, tapped in the popup's sentence.
        let popup = try #require(lines.popup)
        popup.push(await service.lookup(text: "その罪無き人", utf16Offset: 2, showSource: true))
        #expect(lines.highlightedRange(for: "cue-1") == 2..<5)

        // A word from a definition has no sentence: the highlight stays.
        popup.push(await service.lookup(text: "罪", utf16Offset: 0))
        #expect(lines.highlightedRange(for: "cue-1") == 2..<5)

        popup.back()
        popup.back()
        #expect(lines.highlightedRange(for: "cue-1") == 3..<5)

        lines.close()
        #expect(lines.highlight == nil)
    }
}
