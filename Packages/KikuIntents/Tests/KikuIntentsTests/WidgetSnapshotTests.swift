import Foundation
import KikuIntents
import Testing

@Suite struct WidgetSnapshotTests {
    let folder = FileManager.default.temporaryDirectory.appending(path: "WidgetSnapshotTests-\(UUID().uuidString)")

    func item(_ key: String) -> WidgetSnapshot.Item {
        WidgetSnapshot.Item(key: key, itemId: "show-\(key)", title: "第\(key)回", show: "番組", timeLeft: 600, fraction: 0.25)
    }

    @Test func writesOnlyWhenItChanged() throws {
        let store = WidgetSnapshotStore(folder: folder)
        #expect(store.read() == .empty)
        let snapshot = WidgetSnapshot(current: item("1"), isPlaying: true, nextTitle: "Up Next", next: [item("2")], updatedAt: .now)
        #expect(try store.write(snapshot))
        #expect(store.read() == snapshot)
        var later = snapshot
        later.updatedAt = .now.addingTimeInterval(60)
        #expect(try !store.write(later), "only the time differs: no reload")
        later.isPlaying = false
        #expect(try store.write(later))
    }

    @Test func coversAreKeptForWhatsShown() throws {
        let store = WidgetSnapshotStore(folder: folder)
        try store.saveCover(Data([1]), itemId: "show-1")
        try store.saveCover(Data([2]), itemId: "show-2")
        store.pruneCovers(keeping: ["show-2"])
        #expect(!store.hasCover(itemId: "show-1") && store.hasCover(itemId: "show-2"))
        #expect(store.coverURL(itemId: "../x").lastPathComponent == "x.jpg", "no paths in a file name")
    }
}
