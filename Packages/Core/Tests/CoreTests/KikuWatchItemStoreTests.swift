import Core
import Foundation
import Testing

@Suite struct KikuWatchItemStoreTests {
    let day = Date(timeIntervalSince1970: 1_793_400_000)

    @Test func itemsKeepTheirOrderAndSendingAgainReplaces() throws {
        let store = KikuWatchItemStore(database: try AppDatabase.inMemory())
        try store.save(key: "show/b", item: Data("b".utf8), addedAt: day.addingTimeInterval(60))
        try store.save(key: "book", item: Data("a".utf8), addedAt: day)
        #expect(try store.all().map(\.key) == ["book", "show/b"])

        try store.save(key: "book", item: Data("a2".utf8), addedAt: day)
        #expect(try store.all().first?.item == Data("a2".utf8))

        try store.remove("book")
        try store.remove("missing")
        #expect(try store.all().map(\.key) == ["show/b"])
        try store.removeAll()
        #expect(try store.all().isEmpty)
    }

    @Test func listeningRemembersTheVersionApplied() throws {
        let store = KikuWatchListeningStore(database: try AppDatabase.inMemory())
        #expect(try store.applied("s1") == nil)
        try store.markApplied("s1", seconds: 60, endedAt: day, at: day)
        try store.markApplied("s1", seconds: 90, endedAt: day.addingTimeInterval(30), at: day.addingTimeInterval(40))
        let applied = try #require(try store.applied("s1"))
        #expect(applied.seconds == 90 && applied.endedAt == day.addingTimeInterval(30))
        #expect(try store.recent() == ["s1": day.addingTimeInterval(30)])
        #expect(try store.lastAppliedAt() == day.addingTimeInterval(40))
    }

    @Test func rulesAreOffUntilSaved() throws {
        let database = try AppDatabase.inMemory()
        #expect(KikuWatchRules.load(database) == KikuWatchRules())
        #expect(!KikuWatchRules.load(database).isOn)
        try KikuWatchRules(onceStarted: true, ahead: 3, storageLimit: 2_000_000_000).save(database)
        let rules = KikuWatchRules.load(database)
        #expect(rules.isOn && rules.ahead == 3 && rules.keepsManual && rules.storageLimit == 2_000_000_000)
    }

    @Test func declinedItemsStayOffUntilSentByHand() throws {
        let store = KikuWatchDeclinedStore(database: try AppDatabase.inMemory())
        try store.decline("show/a", at: day)
        try store.decline("show/a", at: day)
        #expect(try store.all() == ["show/a"])
        try store.undecline("show/a")
        #expect(try store.all().isEmpty)
    }
}
