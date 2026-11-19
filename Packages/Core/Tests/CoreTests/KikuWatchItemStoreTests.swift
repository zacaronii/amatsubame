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
}
