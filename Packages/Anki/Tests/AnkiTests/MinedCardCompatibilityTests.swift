@testable import Anki
import Core
import Foundation
import Testing

/// A card waiting in the outbox when the app updates is still sent: a card as every release so far
/// has stored it (made-up content) decodes in this build. A change to `MinedCard` must keep this.
@Suite struct MinedCardCompatibilityTests {
    static let queued = #"{"allowDuplicate":false,"content":["sentence","パンを食べる。","expression","食べる","reading","たべる"],"deck":"Test Deck","expression":"食べる","noteType":"Lapis","reading":"たべる","tags":["test"],"version":1,"wantsAudio":true}"#

    @Test func aCardQueuedByAnEarlierBuildStillDecodes() throws {
        let card = try JSONDecoder().decode(MinedCard.self, from: Data(Self.queued.utf8))
        #expect(card.expression == "食べる")
        #expect(card.reading == "たべる")
        #expect(card.content[.sentence] == "パンを食べる。")
        #expect(card.deck == "Test Deck")
        #expect(card.noteType == "Lapis")
        #expect(card.tags == ["test"])
        #expect(card.wantsAudio)
        #expect(card.seriesKey == nil)
    }
}
