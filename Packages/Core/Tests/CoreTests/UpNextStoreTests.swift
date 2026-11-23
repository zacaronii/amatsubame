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

    /// An episode ends: Up Next's first (its library's, else another's), else the show's next
    /// when that's on, else nothing. The first leaves the queue as it starts (`remove`).
    @Test func whatPlaysWhenAnEpisodeEnds() throws {
        let a = item("a"), b = item("b"), other = item("x")
        #expect(UpNextChoice.after(libraryId: "lib", queues: ["lib": [a, b]], playsNextEpisode: true) == .queued(a, libraryId: "lib"))
        #expect(UpNextChoice.after(libraryId: "lib", queues: ["lib": [a, b]], playsNextEpisode: false) == .queued(a, libraryId: "lib"),
                "Up Next plays whatever the show setting")
        #expect(UpNextChoice.after(libraryId: "lib", queues: ["other": [other], "lib": []], playsNextEpisode: true) == .queued(other, libraryId: "other"))
        #expect(UpNextChoice.after(libraryId: "lib", queues: [:], playsNextEpisode: true) == .showsNext)
        #expect(UpNextChoice.after(libraryId: "lib", queues: ["lib": []], playsNextEpisode: false) == .nothing)
        #expect(UpNextChoice.after(libraryId: nil, queues: [:], playsNextEpisode: false) == .nothing)
        // The first played leaves; the next end plays the second.
        let store = UpNextStore(database: try AppDatabase.inMemory())
        try store.set([a, b], libraryId: "lib")
        guard case .queued(let first, let library) = UpNextChoice.after(libraryId: "lib", queues: try store.all(), playsNextEpisode: true) else {
            Issue.record("expected a queued episode"); return
        }
        try store.remove(key: first.key, libraryId: library)
        #expect(UpNextChoice.after(libraryId: "lib", queues: try store.all(), playsNextEpisode: true) == .queued(b, libraryId: "lib"))
    }
}
