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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if only == nil {
                    Picker("Show", selection: $filter) {
                        ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
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
                    Text(filter == .downloaded ? "Downloaded episodes show up here."
                         : environment.library.isOffline ? "Can't reach Audiobookshelf."
                         : filter == .audiobooks || only?.mediaType == .book ? "No audiobooks yet." : "No podcasts yet.")
                        .foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 40)
                }
            }
            .padding()
        }
        .navigationTitle(only?.name ?? "Library")
        .accessibilityIdentifier("library")
        .refreshable {
            CoverLoader.recheck()
            await environment.library.refresh()
        }
    }

    /// "Audiobook · 38%", "Audiobook · Finished", or just "Audiobook" before it's started.
    private func bookLine(_ book: AudiobookshelfItem) -> String {
        guard let progress = environment.library.progress[book.id], progress.currentTime > 0 || progress.isFinished else { return "Audiobook" }
        if progress.isFinished { return "Audiobook · Finished" }
        return "Audiobook · \(Int((progress.progress * 100).rounded()))%"
    }
}
