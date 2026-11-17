import Core
import Foundation
import Testing

@Suite struct LookupCountStoreTests {
    @Test func countsEachLookupAndKeepsFirstAndLastTimes() throws {
        let store = LookupCountStore(database: try AppDatabase.inMemory())
        let first = Date(timeIntervalSince1970: 1_000), later = Date(timeIntervalSince1970: 2_000)
        #expect(try store.record(term: "食べる", reading: "たべる", at: first).lookupCount == 1)
        let row = try store.record(term: "食べる", reading: "たべる", at: later)
        #expect(row.lookupCount == 2 && row.firstLookedUpAt == first && row.lastLookedUpAt == later)
        #expect(try store.count(term: "食べる", reading: "たべる") == 2)
        #expect(try store.count(term: "食べる", reading: "") == 0, "readings are told apart")
    }

    /// Hachidori's identity: trimmed and NFC-normalized, so が typed as か + ゙ meets the same row.
    @Test func termsAreTrimmedAndNormalized() throws {
        let store = LookupCountStore(database: try AppDatabase.inMemory())
        try store.record(term: " 映画 ", reading: "えいが")
        try store.record(term: "映画", reading: "えいが")
        #expect(try store.count(term: "映画", reading: "えいが") == 2)
        try store.record(term: "かぎ", reading: "か\u{3099}き\u{3099}")
        #expect(try store.count(term: "かぎ", reading: "がぎ") == 1)
    }

    @Test func takesTheHostsCount() throws {
        let store = LookupCountStore(database: try AppDatabase.inMemory())
        try store.record(term: "猫", reading: "ねこ")
        try store.setCount(term: "猫", reading: "ねこ", to: 12)
        #expect(try store.count(term: "猫", reading: "ねこ") == 12)
        try store.setCount(term: "犬", reading: "いぬ", to: 3)
        #expect(try store.count(term: "犬", reading: "いぬ") == 3)
    }

    /// Lookups for the host add up in one waiting job per word; once it's being sent, a new one starts.
    @Test func queuesLookupsForTheHostPerWord() throws {
        let outbox = OutboxStore(database: try AppDatabase.inMemory())
        try outbox.queueHostLookupCount(term: "猫", reading: "ねこ")
        try outbox.queueHostLookupCount(term: " 猫", reading: "ねこ")
        try outbox.queueHostLookupCount(term: "犬", reading: "いぬ")
        #expect(try outbox.queuedHostLookupCount(term: "猫", reading: "ねこ") == 2)
        #expect(try outbox.jobs(states: [.pending]).count == 2)

        let claimed = try outbox.claimDueJobs(kinds: [.hachidoriLookupCount])
        #expect(claimed.count == 2)
        try outbox.queueHostLookupCount(term: "猫", reading: "ねこ")
        #expect(try outbox.queuedHostLookupCount(term: "猫", reading: "ねこ") == 3, "in flight still counts")
        let cat = try #require(claimed.first { (try? $0.job.decodePayload(HostLookupCountJob.self))?.term == "猫" })
        _ = try outbox.markSent(try #require(cat.job.id))
        #expect(try outbox.queuedHostLookupCount(term: "猫", reading: "ねこ") == 1)
    }

    @Test func resetStartsEveryWordAgain() throws {
        let store = LookupCountStore(database: try AppDatabase.inMemory())
        try store.record(term: "猫", reading: "ねこ")
        try store.reset()
        #expect(try store.count(term: "猫", reading: "ねこ") == 0)
        #expect(try store.record(term: "猫", reading: "ねこ").lookupCount == 1)
    }

    @Test func countsAreOnByDefault() throws {
        let store = LookupCountStore(database: try AppDatabase.inMemory())
        #expect(try store.settings().showLookupCounts)
        try store.save(PopupSettings(showLookupCounts: false))
        #expect(try !store.settings().showLookupCounts)
    }

    @Test func firstInstallSettingsAreWrittenOnce() throws {
        let store = LookupCountStore(database: try AppDatabase.inMemory())
        #expect(try store.saveFirstInstallSettings())
        #expect(try store.settings() == PopupSettings.firstInstall)
        #expect(try store.settings().showCompactDefinitionSummary)
        #expect(try store.settings().compactDefinitionSummaryCount == 2)

        try store.save(PopupSettings(showCompactDefinitionSummary: false))
        #expect(try !store.saveFirstInstallSettings(), "a saved choice is kept")
        #expect(try !store.settings().showCompactDefinitionSummary)
    }
}
