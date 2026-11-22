import Foundation
import SwiftUI

/// How far along a series, show or book is.
public enum LibraryProgress: Sendable {
    case notStarted, started, finished
}

/// The Mac library toolbar's filter: All, the ones in progress, the untouched ones, the finished ones.
public enum LibraryFilter: String, CaseIterable, Identifiable, Sendable {
    case all, started, notStarted, finished
    public var id: Self { self }

    public func includes(_ progress: LibraryProgress) -> Bool {
        switch self {
        case .all: true
        case .started: progress == .started
        case .notStarted: progress == .notStarted
        case .finished: progress == .finished
        }
    }
}

/// The Mac library toolbar's sort. Titles go A to Z; dates newest first, undated last.
public enum LibrarySort: String, CaseIterable, Identifiable, Sendable {
    case title, recentlyAdded, recentlyOpened
    public var id: Self { self }
}

/// What an app calls the filters and sorts ("Reading", "Unwatched", "Recently Listened").
public struct LibraryWords: Sendable {
    let started: String
    let notStarted: String
    let finished: String
    let recentlyOpened: String

    public init(started: String, notStarted: String, finished: String, recentlyOpened: String) {
        self.started = started
        self.notStarted = notStarted
        self.finished = finished
        self.recentlyOpened = recentlyOpened
    }

    public static let reading = LibraryWords(started: "Reading", notStarted: "Unread", finished: "Finished", recentlyOpened: "Recently Read")
    public static let watching = LibraryWords(started: "Watching", notStarted: "Unwatched", finished: "Watched", recentlyOpened: "Recently Watched")
    public static let listening = LibraryWords(started: "Listening", notStarted: "Not Started", finished: "Finished", recentlyOpened: "Recently Listened")

    public func title(_ filter: LibraryFilter) -> String {
        switch filter {
        case .all: "All"
        case .started: started
        case .notStarted: notStarted
        case .finished: finished
        }
    }

    public func title(_ sort: LibrarySort) -> String {
        switch sort {
        case .title: "Title"
        case .recentlyAdded: "Recently Added"
        case .recentlyOpened: recentlyOpened
        }
    }
}

public extension Array {
    /// The items `filter` keeps, in `sort`'s order.
    func filtered(
        _ filter: LibraryFilter, sortedBy sort: LibrarySort, progress: (Element) -> LibraryProgress,
        title: (Element) -> String, added: (Element) -> Date?, opened: (Element) -> Date?
    ) -> [Element] {
        let kept = filter == .all ? self : self.filter { filter.includes(progress($0)) }
        // Keys worked out once, not in every comparison.
        let keyed = kept.map { item in
            (item: item, title: title(item), date: sort == .recentlyAdded ? added(item) : sort == .recentlyOpened ? opened(item) : nil)
        }
        return keyed.sorted { a, b in
            switch (a.date, b.date) {
            case let (x?, y?) where x != y: x > y
            case (_?, nil): true
            case (nil, _?): false
            default: a.title.localizedStandardCompare(b.title) == .orderedAscending
            }
        }
        .map(\.item)
    }
}

#if os(macOS)
public extension View {
    /// The Mac library toolbar: the filter as a segmented control and a sort menu (search is the
    /// screen's own `.searchable`). `filters`: the ones this library offers.
    func libraryToolbar(
        filter: Binding<LibraryFilter>, sort: Binding<LibrarySort>, words: LibraryWords,
        filters: [LibraryFilter] = LibraryFilter.allCases
    ) -> some View {
        toolbar {
            ToolbarItem(placement: .primaryAction) {
                Picker("Show", selection: filter) {
                    ForEach(filters) { Text(words.title($0)).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .accessibilityIdentifier("library.filter")
            }
            ToolbarItem(placement: .primaryAction) {
                Menu("Sort", systemImage: "arrow.up.arrow.down") {
                    Picker("Sort By", selection: sort) {
                        ForEach(LibrarySort.allCases) { Text(words.title($0)).tag($0) }
                    }
                    .pickerStyle(.inline)
                }
                .accessibilityIdentifier("library.sort")
            }
        }
    }
}
#endif

#if os(iOS)
public extension View {
    /// iPhone and iPad: the same filter and sort as the Mac's toolbar, in one menu (there's no
    /// room for a segmented control beside the title). The icon fills while a filter is on.
    func libraryMenu(
        filter: Binding<LibraryFilter>, sort: Binding<LibrarySort>, words: LibraryWords,
        filters: [LibraryFilter] = LibraryFilter.allCases
    ) -> some View {
        toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker("Show", selection: filter) {
                        ForEach(filters) { Text(words.title($0)).tag($0) }
                    }
                    Picker("Sort By", selection: sort) {
                        ForEach(LibrarySort.allCases) { Text(words.title($0)).tag($0) }
                    }
                } label: {
                    Label("Filter and Sort", systemImage: filter.wrappedValue == .all ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                }
                .accessibilityIdentifier("library.filterMenu")
            }
        }
    }
}
#endif
