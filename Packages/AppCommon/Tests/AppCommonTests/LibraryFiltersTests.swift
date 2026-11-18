import AppCommon
import Foundation
import Testing

@MainActor @Suite struct LibraryFiltersTests {
    struct Item {
        let title: String
        let progress: LibraryProgress
        var added: Date?
        var opened: Date?
    }

    let items = [
        Item(title: "Volume 10", progress: .finished, added: Date(timeIntervalSince1970: 300)),
        Item(title: "volume 2", progress: .started, added: Date(timeIntervalSince1970: 100), opened: Date(timeIntervalSince1970: 50)),
        Item(title: "Another", progress: .notStarted, added: nil, opened: Date(timeIntervalSince1970: 90)),
        Item(title: "Begin", progress: .started, added: Date(timeIntervalSince1970: 300)),
    ]

    func titles(_ filter: LibraryFilter, _ sort: LibrarySort) -> [String] {
        items.filtered(filter, sortedBy: sort, progress: \.progress, title: \.title, added: \.added, opened: \.opened).map(\.title)
    }

    @Test func titlesSortLikeFinder() {
        #expect(titles(.all, .title) == ["Another", "Begin", "volume 2", "Volume 10"])
    }

    @Test func eachFilterKeepsItsOwn() {
        #expect(titles(.started, .title) == ["Begin", "volume 2"])
        #expect(titles(.notStarted, .title) == ["Another"])
        #expect(titles(.finished, .title) == ["Volume 10"])
    }

    /// Newest first; a tie goes by title, and undated ones come last.
    @Test func datesSortNewestFirst() {
        #expect(titles(.all, .recentlyAdded) == ["Begin", "Volume 10", "volume 2", "Another"])
        #expect(titles(.all, .recentlyOpened) == ["Another", "volume 2", "Begin", "Volume 10"])
    }
}
