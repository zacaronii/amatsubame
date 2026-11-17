import AppCommon
import AudiobookshelfKit
import SwiftUI

/// The Library (K2): every show and book in a grid, with a show's new episodes or a book's progress.
struct LibraryView: View {
    @Environment(KikuEnvironment.self) private var environment
    /// One Audiobookshelf library (from the sidebar), or nil for all of them with the filters.
    var only: AudiobookshelfLibrary?

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", podcasts = "Podcasts", audiobooks = "Audiobooks", downloaded = "Downloaded"
        var id: Self { self }
    }

    @State private var filter = Filter.all
    #if os(macOS)
    // The Mac's toolbar filter and sort; Downloaded is in the sidebar instead.
    @AppStorage("library.filter") private var progressFilter = LibraryFilter.all
    @AppStorage("library.sort") private var sort = LibrarySort.title

    private var shows: [AudiobookshelfItem] {
        let library = environment.library
        let items = (library.shows + library.books).filter { only == nil || $0.libraryId == only?.id }
        // Audiobookshelf's times are in milliseconds.
        let listened = Dictionary(library.progress.values.map { ($0.libraryItemId, $0.lastUpdate) }, uniquingKeysWith: max)
        return items.filtered(progressFilter, sortedBy: sort, progress: progress, title: \.title,
                              added: { $0.addedAt.map { Date(timeIntervalSince1970: $0 / 1000) } },
                              opened: { listened[$0.id].map { Date(timeIntervalSince1970: $0 / 1000) } })
    }

    /// A book by its progress. A show: not started until an episode is, then started while it
    /// has new episodes and finished (up to date) when it has none.
    private func progress(_ item: AudiobookshelfItem) -> LibraryProgress {
        let library = environment.library
        if item.isBook {
            guard let progress = library.progress[item.id] else { return .notStarted }
            return progress.isFinished ? .finished : progress.currentTime > 0 ? .started : .notStarted
        }
        guard library.progress.values.contains(where: { $0.libraryItemId == item.id }) else { return .notStarted }
        return (library.newCounts[item.id] ?? 0) > 0 ? .started : .finished
    }

    private var words: LibraryWords {
        only?.mediaType == .podcast
            ? LibraryWords(started: "New Episodes", notStarted: "Not Started", finished: "Up to Date", recentlyOpened: "Recently Listened")
            : .listening
    }
    #else
    /// Shows, then books (each sorted by title).
    private var shows: [AudiobookshelfItem] {
        let library = environment.library
        if let only { return (library.shows + library.books).filter { $0.libraryId == only.id } }
        switch filter {
        case .all: return library.shows + library.books
        case .podcasts: return library.shows
        case .audiobooks: return library.books
        case .downloaded:
            let downloaded = environment.downloadedShowIds
            return (library.shows + library.books).filter { downloaded.contains($0.id) }
        }
    }
    #endif

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                #if os(iOS)
                if only == nil {
                    Picker("Show", selection: $filter) {
                        ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                #endif
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140, maximum: 220), spacing: 16, alignment: .top)], spacing: 20) {
                    ForEach(shows) { show in
                        NavigationLink(value: show.isBook ? ListenRoute.book(show.id) : ListenRoute.show(show.id)) {
                            VStack(alignment: .leading, spacing: 4) {
                                ShowCover(itemId: show.id, cornerRadius: 14)
                                Text(show.title).lineLimit(1).foregroundStyle(.primary)
                                if show.isBook {
                                    Text(bookLine(show)).font(.subheadline).foregroundStyle(.secondary)
                                } else {
                                    let count = environment.library.newCounts[show.id] ?? 0
                                    Text(count > 0 ? "\(count) new" : "Up to date")
                                        .font(.subheadline)
                                        .foregroundStyle(count > 0 ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("library.show")
                    }
                }
                if shows.isEmpty {
                    Text(isFiltered ? "Nothing here." : filter == .downloaded ? "Downloaded episodes show up here."
                         : environment.library.isOffline ? "Can't reach Audiobookshelf."
                         : filter == .audiobooks || only?.mediaType == .book ? "No audiobooks yet." : "No podcasts yet.")
                        .foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 40)
                }
            }
            .padding()
        }
        .navigationTitle(only?.name ?? "Library")
        #if os(macOS)
        .libraryToolbar(filter: $progressFilter, sort: $sort, words: words)
        #endif
        .accessibilityIdentifier("library")
        .refreshable {
            CoverLoader.recheck()
            await environment.library.refresh()
        }
    }

    private var isFiltered: Bool {
        #if os(macOS)
        progressFilter != .all && !environment.library.isOffline
        #else
        false
        #endif
    }

    /// "Audiobook · 38%", "Audiobook · Finished", or just "Audiobook" before it's started.
    private func bookLine(_ book: AudiobookshelfItem) -> String {
        guard let progress = environment.library.progress[book.id], progress.currentTime > 0 || progress.isFinished else { return "Audiobook" }
        if progress.isFinished { return "Audiobook · Finished" }
        return "Audiobook · \(Int((progress.progress * 100).rounded()))%"
    }
}
