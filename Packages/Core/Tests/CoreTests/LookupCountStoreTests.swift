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
}
