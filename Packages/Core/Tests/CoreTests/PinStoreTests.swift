import Core
import Foundation
import Testing

@Suite struct PinStoreTests {
    let day = Date(timeIntervalSince1970: 1_793_400_000)

    @Test func pinsKeepTheirOrderAndRepinningRenames() throws {
        let store = PinStore(database: try AppDatabase.inMemory())
        try store.pin(PinnedItem(id: "2", kind: "series", title: "Second", pinnedAt: day.addingTimeInterval(60)))
        try store.pin(PinnedItem(id: "1", kind: "series", title: "First", pinnedAt: day))
        #expect(try store.all().map(\.id) == ["1", "2"])

        try store.pin(PinnedItem(id: "1", kind: "series", title: "Renamed", pinnedAt: day.addingTimeInterval(120)))
        #expect(try store.all().map(\.title) == ["Renamed", "Second"])

        try store.unpin(id: "1")
        try store.unpin(id: "missing")
        #expect(try store.all().map(\.id) == ["2"])
    }
}
