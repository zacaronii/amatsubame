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

    /// The highlight follows the word the popup shows: a word from a definition (which has no
    /// place in the line) leaves it, Back keeps it, and closing clears it.
    @Test func theHighlightFollowsThePopup() async throws {
        let service = try await service()
        let lines = LineLookup(service: service)
        lines.lookUp("その罪無き人", characterIndex: 3, key: "cue-1", context: nil)
        while lines.popup == nil { await Task.yield() }
        #expect(lines.highlight?.key == "cue-1")
        #expect(lines.highlightedRange(for: "cue-1") == 3..<5, "無き")
        #expect(lines.highlightedRange(for: "cue-2") == nil)

        // A word from a definition: the highlight stays on the line's word.
        let popup = try #require(lines.popup)
        popup.push(await service.lookup(text: "罪", utf16Offset: 0))
        #expect(lines.highlightedRange(for: "cue-1") == 3..<5)

        popup.back()
        #expect(lines.highlightedRange(for: "cue-1") == 3..<5)

        lines.close()
        #expect(lines.highlight == nil)
    }

    /// A card's source: show, episode and time; without an episode (a film, or a book position
    /// before its first chapter) just the show and time, never an empty " · ".
    @Test func cardSourceSkipsAnEmptyEpisode() {
        #expect(CardSource.miscInfo(show: "Star Captain", episode: "S2E11", time: 1116) == "Star Captain — S2E11 · 18:36")
        #expect(CardSource.miscInfo(show: "Star Captain", episode: nil, time: 1116) == "Star Captain — 18:36")
        #expect(CardSource.miscInfo(show: "本", episode: "", time: 4399) == "本 — 1:13:19")
    }
}
