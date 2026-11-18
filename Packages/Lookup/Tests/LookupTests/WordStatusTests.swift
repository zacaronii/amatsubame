import Core
import Foundation
import HachidoriKit
@testable import Lookup
import Testing

/// Known and ignored words: the popup's toggles, the word marks, and Hachidori's list.
@Suite @MainActor struct WordStatusTests {
    func mining(_ database: AppDatabase) -> MiningService {
        let mining = MiningService(outbox: OutboxStore(database: database), media: OutboxMediaStorage(directory: FileManager.default.temporaryDirectory),
                                   settings: AnkiSettingsStore(database: database), minedWords: MinedWordStore(database: database))
        mining.ankiConnected = true
        return mining
    }

    @Test func togglesLikeHachidoriAndHidesMarks() async throws {
        let service = try await LookupServiceTests().makeService()
        let mining = mining(try AppDatabase.inMemory())
        service.mining = mining
        #expect(mining.wordMarks().state(expression: "映画", reading: "えいが") == .notInAnki)

        #expect(service.toggleWordStatus(.known, for: "映画") == .known)
        #expect(mining.wordMarks().state(expression: "映画", reading: "えいが") == .known, "never marked")
        #expect(service.toggleWordStatus(.ignored, for: "映画") == .ignored, "the other button switches")
        #expect(service.toggleWordStatus(.ignored, for: "映画") == nil, "the pressed one clears")
        #expect(mining.wordMarks().state(expression: "映画", reading: "えいが") == .notInAnki)
        #expect(try service.wordStatusStore.pendingHost().isEmpty, "no Hachidori")
    }

    @Test func thePopupHasTheButtonsWhileWordsAreMarked() async throws {
        let service = try await LookupServiceTests().makeService()
        let page = await service.lookup(text: "映画", utf16Offset: 0)
        #expect(!service.document(for: page).contains(#"class="status-button""#), "no Anki, no marks")
        service.mining = mining(try AppDatabase.inMemory())
        service.toggleWordStatus(.known, for: "映画")
        let html = service.document(for: page)
        #expect(html.contains(#"data-action="known" data-index="0" data-headword="映画" aria-pressed="true""#))
        #expect(html.contains(#"data-action="ignored" data-index="0" data-headword="映画" aria-pressed="false""#))
    }

    /// With Hachidori on, a mark waits for it and a job is queued; the host's list is taken,
    /// except for that waiting change.
    @Test func sharesTheListWithHachidori() async throws {
        let service = try await LookupServiceTests().makeService()
        let outbox = OutboxStore(database: try AppDatabase.inMemory())
        service.hostOutbox = (outbox, {})
        service.sharesWithHost = { true }
        service.toggleWordStatus(.ignored, for: "食べる")
        #expect(try service.wordStatusStore.pendingHost().map(\.headword) == ["食べる"])
        #expect(try outbox.waitingCounts()[.hachidoriWordStatus] == 1)

        _ = try await HostLookupTests().linked(service, snapshot: ["wordStatusOverrides": ["revision": 2, "known": ["映画", "食べる"], "ignored": []]])
        #expect(service.wordStatus(of: "映画") == .known, "from the host")
        #expect(service.wordStatus(of: "食べる") == .ignored, "ours, not sent yet")
        service.host = nil
    }
}
