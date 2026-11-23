import Core
import Foundation
import Testing

@Suite struct UpNextStoreTests {
    func item(_ episode: String) -> UpNextItem { UpNextItem(itemId: "show", episodeId: episode, title: episode, showTitle: "番組") }

    @Test func playNextPlayLastMoveRemove() throws {
        let store = UpNextStore(database: try AppDatabase.inMemory())
        try store.playLast(item("a"), libraryId: "lib")
        try store.playLast(item("b"), libraryId: "lib")
        try store.playNext(item("c"), libraryId: "lib")
        #expect(try store.items(libraryId: "lib").map(\.episodeId) == ["c", "a", "b"])
        try store.playLast(item("c"), libraryId: "lib")
        #expect(try store.items(libraryId: "lib").map(\.episodeId) == ["a", "b", "c"], "queued again: moved, not doubled")
        try store.move(from: [2], to: 0, libraryId: "lib")
        #expect(try store.items(libraryId: "lib").map(\.episodeId) == ["c", "a", "b"])
        try store.move(from: [0], to: 3, libraryId: "lib")
        #expect(try store.items(libraryId: "lib").map(\.episodeId) == ["a", "b", "c"])
        #expect(try store.remove(key: item("b").key, libraryId: "lib")?.map(\.episodeId) == ["a", "c"])
        #expect(try store.remove(key: item("zz").key, libraryId: "lib") == nil, "not queued")
        #expect(try store.items(libraryId: "other").isEmpty)
        #expect(try store.all().keys.sorted() == ["lib"])
    }

    @Test func playlistIdIsKeptPerLibrary() throws {
        let store = UpNextStore(database: try AppDatabase.inMemory())
        #expect(try store.playlistId(libraryId: "lib") == nil)
        try store.setPlaylistId("pl-1", libraryId: "lib")
        #expect(try store.playlistId(libraryId: "lib") == "pl-1")
        try store.setPlaylistId(nil, libraryId: "lib")
        #expect(try store.playlistId(libraryId: "lib") == nil)
    }
}
