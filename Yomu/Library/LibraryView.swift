import AppCommon
import Core
import KavitaKit
import SwiftUI

@MainActor @Observable
final class LibraryModel {
    var libraries: [KavitaLibrary] = []
    var continueReading: [KavitaSeries] = []
    /// "Vol. 1 · p. 11" for each Continue Reading series, by series id.
    var continueLabels: [Int: String] = [:]
    /// A book series' share read in characters, for its Continue Reading bar.
    var continueFractions: [Int: Double] = [:]
    /// Each library's most recently added series, by library id.
    var shelves: [Int: [KavitaSeries]] = [:]
    var today: TodaySummary?
    var error: String?
    var isRefreshing = false

    /// Libraries the app can read (manga and books); Settings decides which are shown.
    static func readable(_ library: KavitaLibrary) -> Bool {
        library.isMangaReadable || library.isBookLibrary
    }

    static let shelfLength = 12

    func load(_ environment: AppEnvironment) async {
        let repository = environment.kavitaLibrary
        libraries = ((try? repository.cachedLibraries()) ?? []).filter(Self.readable)
        continueReading = offlineShelf(environment)
        for library in libraries where shelves[library.id] == nil {
            shelves[library.id] = Array(((try? repository.cachedSeries(libraryId: library.id)) ?? []).prefix(Self.shelfLength))
        }
        labelContinueReading(environment, refresh: false)
        guard let client = environment.kavitaClient() else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            libraries = try await repository.refreshLibraries(using: client).filter(Self.readable)
            NotificationCenter.default.post(name: .kavitaLibrariesDidChange, object: nil)
            let readable = Set(libraries.map(\.id))
            let onDeck = try await client.onDeck().filter { readable.contains($0.0.libraryId) }
            try? repository.remember(onDeck)
            continueReading = onDeck.map(\.0)
            error = nil
            environment.noteKavitaRefresh(error: nil)
        } catch {
            guard !error.isCancellation else { return }
            self.error = error.localizedDescription
            environment.noteKavitaRefresh(error: error)
            return
        }
        labelContinueReading(environment, refresh: false)
        let visible = libraries.filter { !environment.hiddenLibraries.contains($0.id) }
        await withTaskGroup(of: (Int, [KavitaSeries]?).self) { group in
            for library in visible {
                group.addTask { (library.id, try? await client.recentlyAdded(libraryId: library.id, limit: Self.shelfLength)) }
            }
            for await (id, series) in group {
                if let series { shelves[id] = series }
            }
        }
        labelContinueReading(environment, refresh: true)
        environment.bookCounter.countNewVolumes()
    }

    func loadToday(_ environment: AppEnvironment) {
        today = TodaySummary.load(kind: .reading, environment: environment.common)
        Task { today = await TodaySummary.refreshed(kind: .reading, environment: environment.common) }
    }

    /// Where each Continue Reading series picks up, from its volumes (cached, then refreshed).
    private func labelContinueReading(_ environment: AppEnvironment, refresh: Bool) {
        let repository = environment.kavitaLibrary
        let series = continueReading
        Task {
            for item in series {
                if let volumes = try? repository.cachedVolumes(seriesId: item.id), !volumes.isEmpty {
                    await label(KavitaSeriesContents(volumes: volumes), series: item, environment)
                }
            }
            guard refresh, let client = environment.kavitaClient() else { return }
            for item in series {
                guard let volumes = try? await repository.refreshVolumes(seriesId: item.id, using: client) else { continue }
                await label(KavitaSeriesContents(volumes: volumes), series: item, environment)
            }
        }
    }

    /// The Continue label and bar; a book's in characters (`BookCharacters`).
    private func label(_ contents: KavitaSeriesContents, series: KavitaSeries, _ environment: AppEnvironment) async {
        guard series.isEpub, let chapter = contents.continueChapter else {
            continueLabels[series.id] = contents.continueLabel(isEpub: series.isEpub)
            return
        }
        let length = try? environment.bookLengths.length(chapterId: chapter.id)
        let local = try? environment.readingProgress.progress(chapterId: chapter.id)
        continueLabels[series.id] = contents.continueLabel(isEpub: true) { BookCharacters.progress($0, length: length, local: local) }
        continueFractions[series.id] = environment.bookProgress(seriesId: series.id)?.fraction
    }

    /// Without a connection, the shelf comes from what was read on this device.
    private func offlineShelf(_ environment: AppEnvironment) -> [KavitaSeries] {
        let recent = (try? environment.readingProgress.recentlyRead()) ?? []
        return recent.compactMap { try? environment.kavitaLibrary.cachedSeries(id: $0.seriesId) }
    }
}

struct LibraryView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = LibraryModel()
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if !environment.common.accountsLoaded {
                    // The server details are still being read: not "no server" yet.
                    ProgressView()
                } else if environment.serverAccounts[.kavita] == nil {
                    ContentUnavailableView(
                        "Connect Kavita",
                        systemImage: "books.vertical",
                        description: Text("Add your Kavita server in Settings to browse your manga and books.")
                    )
                } else {
                    content
                }
            }
            .navigationTitle("Library")
            .navigationDestination(for: KavitaLibrary.self) { SeriesGridView(library: $0) }
            // From the iPad's sidebar: the library on its own, in this tab.
            .onChange(of: environment.requestedLibrary, initial: true) { _, library in
                guard let library else { return }
                environment.requestedLibrary = nil
                path = NavigationPath([library])
            }
            .navigationDestination(for: KavitaSeries.self) { SeriesDetailView(series: $0) }
            .toolbar {
                if model.isRefreshing {
                    ToolbarItem { ProgressView() }
                }
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink {
                        LibrarySearchView()
                    } label: {
                        Label("Search", systemImage: "magnifyingglass")
                    }
                    .accessibilityIdentifier("library.search")
                }
            }
        }
        .task(id: environment.serverAccounts[.kavita]?.baseURL) { await model.load(environment) }
        .onAppear { model.loadToday(environment) }
        .onReceive(NotificationCenter.default.publisher(for: .readerDidClose)) { _ in model.loadToday(environment) }
        // Back from the background (another day, or reading elsewhere).
        .onChange(of: scenePhase) { _, phase in if phase == .active { model.loadToday(environment) } }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                let offline = environment.isLibraryOffline
                if offline {
                    Label("Offline: showing downloaded series", systemImage: "wifi.slash")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                        .accessibilityIdentifier("library.offline")
                } else if let error = model.error {
                    Label(error, systemImage: "wifi.exclamationmark")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
                if let today = model.today {
                    TodayRow(kind: .reading, today: today) { environment.selectedTab = .stats }
                }
                let downloaded = environment.downloadedSeriesIds
                let continueReading = model.continueReading.filter {
                    !environment.hiddenLibraries.contains($0.libraryId) && (!offline || downloaded.contains($0.id))
                }
                if !continueReading.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Continue Reading").font(.title2.bold())
                        ScrollView(.horizontal) {
                            LazyHStack(alignment: .top, spacing: 14) {
                                ForEach(continueReading) { series in
                                    NavigationLink(value: series) {
                                        ContinueTile(series: series, label: model.continueLabels[series.id], fraction: model.continueFractions[series.id])
                                            .frame(width: 150)
                                    }
                                    .accessibilityIdentifier("shelf.\(series.name)")
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .scrollIndicators(.hidden)
                        .shelfScrollClip()
                    }
                }
                shelves(offline: offline, downloaded: downloaded)
            }
            .padding()
        }
        .refreshable {
            CoverLoader.recheck()
            await model.load(environment)
        }
    }

    /// One row per visible library: its newest series, with "See All".
    @ViewBuilder private func shelves(offline: Bool, downloaded: Set<Int>) -> some View {
        let downloadedLibraries = Set(downloaded.compactMap { try? environment.kavitaLibrary.cachedSeries(id: $0)?.libraryId })
        let libraries = model.libraries.filter {
            !environment.hiddenLibraries.contains($0.id) && (!offline || downloadedLibraries.contains($0.id))
        }
        if libraries.isEmpty && !model.isRefreshing {
            Text(offline ? "Nothing downloaded yet. Download volumes from a series to read them offline."
                 : model.libraries.isEmpty ? "No libraries yet." : "All libraries are turned off in Settings → Libraries.")
                .foregroundStyle(.secondary)
        }
        ForEach(libraries) { library in
            let series = (model.shelves[library.id] ?? []).filter { !offline || downloaded.contains($0.id) }
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    NavigationLink(value: library) {
                        Text(library.name).font(.title2.bold()).foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    NavigationLink(value: library) { Text("See All") }
                        .accessibilityIdentifier("library.seeAll.\(library.name)")
                }
                if !series.isEmpty {
                    ScrollView(.horizontal) {
                        LazyHStack(alignment: .top, spacing: 12) {
                            ForEach(series) { item in
                                NavigationLink(value: item) {
                                    SeriesTile(series: item).frame(width: 110)
                                }
                                .accessibilityIdentifier("home.series.\(item.name)")
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                    .shelfScrollClip()
                }
            }
        }
    }
}

/// A Continue Reading cover: a thin progress bar under it, the title and where reading picks up.
struct ContinueTile: View {
    @Environment(AppEnvironment.self) private var environment
    let series: KavitaSeries
    let label: String?
    /// A book's share read in characters; manga's comes from Kavita's pages.
    var fraction: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CoverImage(request: environment.kavitaClient()?.seriesCoverRequest(seriesId: series.id))
            ProgressView(value: series.isEpub ? fraction ?? 0 : Double(min(series.pagesRead, series.pages)) / Double(max(series.pages, 1)))
                .tint(.accentColor)
            Text(series.displayName)
                .font(.subheadline)
                .lineLimit(1)
            Text(label ?? " ")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

struct SeriesTile: View {
    @Environment(AppEnvironment.self) private var environment
    let series: KavitaSeries
    /// A book series' share read in characters (`BookCharacters`), once its volumes are known.
    @State private var bookFraction: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CoverImage(request: environment.kavitaClient()?.seriesCoverRequest(seriesId: series.id))
                .overlay(alignment: .bottom) {
                    if let fraction, fraction > 0 {
                        ProgressView(value: fraction)
                            .tint(.accentColor)
                            .padding(6)
                    }
                }
            Text(series.displayName)
                .font(.caption)
                .lineLimit(2, reservesSpace: true)
                .multilineTextAlignment(.leading)
        }
        .task(id: series.pagesRead) {
            if series.isEpub { bookFraction = environment.bookProgress(seriesId: series.id)?.fraction }
        }
    }

    /// Books in characters, never Kavita's page share (their sections vary a lot); manga in pages.
    private var fraction: Double? {
        if series.isEpub { return bookFraction }
        return series.pages > 0 ? Double(min(series.pagesRead, series.pages)) / Double(series.pages) : nil
    }
}

/// Series in every library by name (Kavita's search), opening their pages.
struct LibrarySearchView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var query = ""
    @State private var results: [KavitaSearchSeries] = []
    @State private var error: String?

    var body: some View {
        List {
            if let error {
                Label(error, systemImage: "wifi.exclamationmark").foregroundStyle(.secondary)
            }
            ForEach(results) { result in
                NavigationLink {
                    SearchResultSeries(result: result)
                } label: {
                    HStack(spacing: 12) {
                        CoverImage(request: environment.kavitaClient()?.seriesCoverRequest(seriesId: result.seriesId))
                            .frame(width: 44)
                        VStack(alignment: .leading) {
                            Text(result.name)
                            if let library = result.libraryName {
                                Text(library).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .accessibilityIdentifier("search.result")
            }
        }
        .overlay {
            if results.isEmpty && !query.isEmpty && error == nil {
                ContentUnavailableView.search(text: query)
            }
        }
        .searchable(text: $query, placement: .automatic, prompt: "Series")
        .navigationTitle("Search")
        .task(id: query) {
            let text = query.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, let client = environment.kavitaClient() else { results = []; return }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            do {
                results = try await client.search(text)
                error = nil
            } catch {
                guard !error.isCancellation else { return }
                self.error = error.localizedDescription
            }
        }
    }
}

/// A search result's series page, once the series has loaded (the cache first).
private struct SearchResultSeries: View {
    @Environment(AppEnvironment.self) private var environment
    let result: KavitaSearchSeries
    @State private var series: KavitaSeries?
    @State private var error: String?

    var body: some View {
        Group {
            if let series {
                SeriesDetailView(series: series)
            } else if let error {
                ContentUnavailableView("Couldn't Open the Series", systemImage: "wifi.exclamationmark", description: Text(error))
            } else {
                ProgressView()
            }
        }
        .task {
            if let cached = try? environment.kavitaLibrary.cachedSeries(id: result.seriesId) { series = cached }
            guard let client = environment.kavitaClient() else { return }
            do {
                series = try await client.series(id: result.seriesId)
            } catch {
                guard !error.isCancellation, series == nil else { return }
                self.error = error.localizedDescription
            }
        }
    }
}

#Preview {
    LibraryView().environment(AppEnvironment.preview())
}

extension Notification.Name {
    /// The Kavita library list was refreshed (the sidebar lists them).
    static let kavitaLibrariesDidChange = Notification.Name("kavitaLibrariesDidChange")
}
