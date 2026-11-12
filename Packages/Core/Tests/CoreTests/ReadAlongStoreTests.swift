import Core
import Foundation
import Testing

@Suite struct ReadAlongStoreTests {
    @Test func pairsByBookNewestFirst() throws {
        let store = ReadAlongStore(database: try AppDatabase.inMemory())
        let start = Date(timeIntervalSince1970: 1_794_000_000)
        try store.pair(ReadAlongPair(chapterId: 1, itemId: "book", bookTitle: "空の手紙", createdAt: start))
        try store.pair(ReadAlongPair(chapterId: 2, itemId: "book", bookTitle: "空の手紙", createdAt: start.addingTimeInterval(60)))
        try store.pair(ReadAlongPair(chapterId: 3, itemId: "other", bookTitle: "別の本", createdAt: start))
        #expect(try store.pairs(itemId: "book").map(\.chapterId) == [2, 1])
        #expect(try store.pairs(itemId: "missing").isEmpty)
    }

    /// Read-along is on for a new pairing; switching it off is kept with the pair.
    @Test func readingAlongCanBeSwitchedOff() throws {
        let store = ReadAlongStore(database: try AppDatabase.inMemory())
        try store.pair(ReadAlongPair(chapterId: 1, itemId: "book", bookTitle: "空の手紙", createdAt: .now))
        #expect(try store.pair(chapterId: 1)?.readsAlong == true)
        try store.setReadsAlong(chapterId: 1, false)
        #expect(try store.pair(chapterId: 1)?.readsAlong == false)
    }
}
