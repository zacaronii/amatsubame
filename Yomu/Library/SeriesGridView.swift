import AppCommon
import Core
import KavitaKit
import SwiftUI

struct SeriesGridView: View {
    @Environment(AppEnvironment.self) private var environment
    let library: KavitaLibrary
    @State private var series: [KavitaSeries] = []
    @State private var error: String?
    @State private var isRefreshing = false
    @State private var search = ""
    @State private var shelf = Shelf.all
    @State private var cacheBytes = 0
    #if os(macOS)
    // The Mac's toolbar filter and sort; Downloaded is in the sidebar instead.
    @AppStorage("library.filter") private var filter = LibraryFilter.all
    @AppStorage("library.sort") private var sort = LibrarySort.title
    #endif

    /// All · Reading (started, not finished) · Downloaded.
    enum Shelf: String, CaseIterable {
        case all = "All", reading = "Reading", downloaded = "Downloaded"
    }

    private var filtered: [KavitaSeries] {
        // Offline, only series with something downloaded can be read.
        let downloaded = environment.downloadedSeriesIds
        var series = environment.isLibraryOffline || shelf == .downloaded ? series.filter { downloaded.contains($0.id) } : series
        if shelf == .reading { series = series.filter { $0.progress == .started } }
        #if os(macOS)
        series = series.filtered(filter, sortedBy: sort, progress: \.progress, title: { $0.sortName ?? $0.name },
                                 added: \.created, opened: \.latestReadDate)
        #endif
        guard !search.isEmpty else { return series }
        return series.filter { $0.displayName.localizedCaseInsensitiveContains(search) || $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        ScrollView {
            if let error {
                Label(error, systemImage: "wifi.exclamationmark")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            }
            #if os(iOS)
            shelfPicker.padding(.horizontal)
            #endif
            if shelf == .downloaded {
                OnDeviceCard(downloads: downloadedBytes, cache: Int64(cacheBytes))
                    .padding(.horizontal)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110, maximum: 180), spacing: 16)], spacing: 20) {
                ForEach(filtered) { item in
                    NavigationLink(value: item) {
                        SeriesTile(series: item)
                    }
                    .accessibilityIdentifier("series.\(item.name)")
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
        .overlay {
            if series.isEmpty && isRefreshing {
                ProgressView()
            } else if filtered.isEmpty && search.isEmpty && !isRefreshing {
                #if os(macOS)
                if filter == .notStarted, !environment.isLibraryOffline {
                    ContentUnavailableView("Nothing Unread", systemImage: "book.closed")
                } else if filter == .finished, !environment.isLibraryOffline {
                    ContentUnavailableView("Nothing Finished", systemImage: "checkmark.circle")
                } else {
                    emptyShelf(reading: filter == .started)
                }
                #else
                emptyShelf(reading: shelf == .reading)
                #endif
            }
        }
        .searchable(text: $search, prompt: "Filter")
        .navigationTitle(library.name)
        #if os(macOS)
        .libraryToolbar(filter: $filter, sort: $sort, words: .reading)
        #endif
        .refreshable {
            CoverLoader.recheck()
            await load()
        }
        .task { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .refreshLibrary)) { _ in Task { await load() } }
        .task(id: shelf) {
            guard shelf == .downloaded else { return }
            cacheBytes = await environment.books.unpinnedBytes() + ((try? environment.pageCache.unpinnedBytes()) ?? 0)
        }
    }

    @ViewBuilder
    private func emptyShelf(reading: Bool) -> some View {
        if reading {
            ContentUnavailableView("Nothing Being Read", systemImage: "book",
                                   description: Text("Series you've started and haven't finished show here."))
        } else if environment.isLibraryOffline || shelf == .downloaded {
            ContentUnavailableView("Nothing Downloaded", systemImage: "wifi.slash",
                                   description: Text("Series with downloaded volumes show here while you're offline."))
        } else {
            ContentUnavailableView("No Series", systemImage: "books.vertical")
        }
    }

    #if os(iOS)
    private var shelfPicker: some View {
        Picker("Show", selection: $shelf) {
            ForEach(Shelf.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("shelf.filter")
    }
    #endif

    /// Everything downloaded on this device (all libraries), as Settings ▸ Storage counts it.
    private var downloadedBytes: Int64 {
        environment.downloader.records.values.reduce(0) { $0 + ($1.state == .done ? ($1.bytesTotal ?? 0) : $1.bytesDone) }
    }

    private func load() async {
        let repository = environment.kavitaLibrary
        series = (try? repository.cachedSeries(libraryId: library.id)) ?? []
        guard let client = environment.kavitaClient() else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            series = try await repository.refreshSeries(libraryId: library.id, using: client)
            error = nil
            environment.noteKavitaRefresh(error: nil)
        } catch {
            guard !error.isCancellation else { return }
            environment.noteKavitaRefresh(error: error)
            self.error = environment.isLibraryOffline ? "Offline: showing downloaded series."
                : series.isEmpty ? error.localizedDescription : "Offline: showing saved list."
        }
    }
}

extension KavitaSeries {
    var progress: LibraryProgress {
        pagesRead == 0 ? .notStarted : pages > 0 && pagesRead >= pages ? .finished : .started
    }
}

/// "On this device": downloads and cache, with a way to Settings ▸ Storage.
struct OnDeviceCard: View {
    let downloads: Int64
    let cache: Int64

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("On this device").font(.headline)
                Spacer()
                Text((downloads + cache).storageText).foregroundStyle(.secondary)
            }
            GeometryReader { geometry in
                let total = max(Double(downloads + cache), 1)
                HStack(spacing: 0) {
                    Rectangle().fill(.tint).frame(width: geometry.size.width * Double(downloads) / total)
                    Rectangle().fill(.secondary).frame(width: geometry.size.width * Double(cache) / total)
                    Spacer(minLength: 0)
                }
                .background(.quaternary)
                .clipShape(.capsule)
            }
            .frame(height: 6)
            HStack(spacing: 16) {
                legend("Downloads", downloads, color: AnyShapeStyle(.tint))
                legend("Cache", cache, color: AnyShapeStyle(.secondary))
            }
            .font(.subheadline)
            NavigationLink("Manage Storage") { StorageView() }
                .accessibilityIdentifier("shelf.manageStorage")
        }
        .padding()
        .background(.background.secondary, in: .rect(cornerRadius: 16))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("shelf.onDevice")
    }

    private func legend(_ title: String, _ bytes: Int64, color: AnyShapeStyle) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text("\(title) \(bytes.storageText)").foregroundStyle(.secondary)
        }
    }
}
