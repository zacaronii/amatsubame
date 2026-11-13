import AppCommon
import Core
import JellyfinKit
import SwiftUI

/// Home: Today, Continue Watching (in progress), Next Up and each library's newest shows.
struct WatchView: View {
    /// The Watch tab's navigation (a suggestion from the player opens a series here).
    @State private var path: [JellyfinItem] = []
    @Environment(PlayerEnvironment.self) private var environment
    @Environment(CommonEnvironment.self) private var common
    @Environment(\.scenePhase) private var scenePhase
    @State private var continueWatching: [JellyfinItem] = []
    @State private var nextUp: [JellyfinItem] = []
    @State private var allNextUp: [JellyfinItem] = []
    @State private var libraries: [JellyfinItem] = []
    /// Each library's newest shows, by library id.
    @State private var shelves: [String: [JellyfinItem]] = [:]
    @State private var today: TodaySummary?
    @State private var error: String?
    @State private var isLoading = false
    @State private var playback: PlaybackSession?
    #if DEBUG
    private static var openedDebugItem = false
    private static var startedDebugDownload = false
    #endif

    private var onDevice: [DownloadRecord] {
        environment.downloader.records.values.filter { $0.state == .done }.sorted { $0.createdAt > $1.createdAt }
    }

    private var visibleLibraries: [JellyfinItem] {
        libraries.filter { !environment.hiddenLibraries.contains($0.id) }
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if common.serverAccounts[.jellyfin]?.userId == nil {
                    ContentUnavailableView(
                        "Connect Jellyfin",
                        systemImage: "play.rectangle",
                        description: Text("Sign in to your Jellyfin server in Settings.")
                    )
                    .accessibilityIdentifier("watch.placeholder")
                } else {
                    home
                }
            }
            .navigationTitle("Watch")
            .toolbar {
                if common.serverAccounts[.jellyfin]?.userId != nil {
                    ToolbarItem(placement: .primaryAction) {
                        NavigationLink {
                            JellyfinSearchView(playback: $playback)
                        } label: {
                            Label("Search", systemImage: "magnifyingglass")
                        }
                        .accessibilityIdentifier("watch.search")
                    }
                }
            }
            .navigationDestination(for: JellyfinItem.self) { item in
                if item.type == "CollectionFolder" {
                    JellyfinLibraryView(library: item)
                } else {
                    SeriesView(series: item, playback: $playback)
                }
            }
        }
        .playbackPresentation($playback)
        .onChange(of: environment.openSeriesRequest, initial: true) { _, series in
            guard let series else { return }
            path = [series]
            environment.openSeriesRequest = nil
        }
        .task(id: common.serverAccounts[.jellyfin]?.userId) { await load() }
        .onChange(of: environment.japaneseOnlyLibraries) { Task { await loadShelves() } }
        #if DEBUG
        .task {
            // Debug only: PLAYER_OPEN_ITEM=<Jellyfin item id> opens it straight away (live checks).
            if let itemId = ProcessInfo.processInfo.environment["PLAYER_OPEN_ITEM"], !Self.openedDebugItem {
                Self.openedDebugItem = true
                // PLAYER_OPEN_AT=<seconds> starts there (e.g. near the end, for Up Next).
                playback = PlaybackSession(itemId: itemId, title: "",
                                           startAt: ProcessInfo.processInfo.environment["PLAYER_OPEN_AT"].flatMap(Double.init))
            }
            // UI tests: UITEST_PLAYER_VIDEO=<path> plays a local file (gesture tests).
            if let path = ProcessInfo.processInfo.environment["UITEST_PLAYER_VIDEO"], !Self.openedDebugItem {
                Self.openedDebugItem = true
                playback = PlaybackSession(itemId: path, title: "Test Video")
            }
            // PLAYER_DOWNLOAD_ITEM=<id> starts downloading it (live checks of downloads).
            if let itemId = ProcessInfo.processInfo.environment["PLAYER_DOWNLOAD_ITEM"], !Self.startedDebugDownload,
               let client = environment.jellyfinClient(), let item = try? await client.item(id: itemId) {
                Self.startedDebugDownload = true
                await environment.downloader.download(item)
            }
        }
        #endif
        .onReceive(NotificationCenter.default.publisher(for: .playbackDidClose)) { _ in
            loadToday()
            Task { await load() }
        }
        .onAppear { loadToday() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { loadToday() } }
    }

    /// At once from the device, then with the mining deck asked for again.
    private func loadToday() {
        today = TodaySummary.load(kind: .watching, environment: common)
        Task { today = await TodaySummary.refreshed(kind: .watching, environment: common) }
    }

    private var home: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let error {
                    Label(error, systemImage: "wifi.exclamationmark")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if let today {
                    TodayRow(kind: .watching, today: today) { environment.selectedTab = .stats }
                }
                if !continueWatching.isEmpty {
                    section("Continue Watching") {
                        ScrollView(.horizontal) {
                            LazyHStack(alignment: .top, spacing: 14) {
                                ForEach(continueWatching) { item in
                                    Button {
                                        playback = PlaybackSession(item: item)
                                    } label: {
                                        ContinueTile(item: item)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityIdentifier("continue.\(item.id)")
                                    .contextMenu { downloadMenu(item) }
                                }
                            }
                            .scrollTargetLayout()
                        }
                        .scrollIndicators(.hidden)
                        .shelfScrollClip()
                    }
                }
                if !nextUp.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("Next Up").font(.title2.bold())
                            Spacer()
                            if allNextUp.count > nextUp.count {
                                NavigationLink("See All") {
                                    ScrollView { nextUpRows(allNextUp).padding() }
                                        .navigationTitle("Next Up")
                                }
                                .accessibilityIdentifier("nextUp.seeAll")
                            }
                        }
                        nextUpRows(nextUp)
                    }
                }
                if error != nil, !onDevice.isEmpty {
                    // Jellyfin is unreachable: what can still be watched.
                    section("On This Device") {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(onDevice) { record in
                                Button {
                                    playback = PlaybackSession(itemId: record.itemKey, title: [record.seriesTitle, record.title]
                                        .joined(separator: " · "))
                                } label: {
                                    Label("\(record.seriesTitle) · \(record.title)", systemImage: "arrow.down.circle.fill")
                                }
                                .accessibilityIdentifier("watch.onDevice")
                            }
                        }
                    }
                }
                ForEach(visibleLibraries) { library in
                    LibraryShelf(library: library, items: shelves[library.id] ?? [])
                }
            }
            .padding()
        }
        .overlay {
            if libraries.isEmpty && isLoading { ProgressView() }
        }
        .refreshable {
            CoverLoader.recheck()
            await load()
        }
    }

    private func nextUpRows(_ items: [JellyfinItem]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index > 0 { Divider().padding(.leading, 120) }
                Button {
                    playback = PlaybackSession(item: item)
                } label: {
                    NextUpRow(item: item)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("nextUp.\(item.id)")
                .contextMenu { downloadMenu(item) }
            }
        }
        .padding(.horizontal)
        .background(.background.secondary, in: .rect(cornerRadius: 16))
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.title2.bold())
            content()
        }
    }

    @ViewBuilder private func downloadMenu(_ item: JellyfinItem) -> some View {
        if let record = environment.downloader.records[item.id] {
            Button("Delete Download", systemImage: "trash", role: .destructive) {
                Task { await environment.downloader.delete(record) }
            }
        } else {
            Button("Download", systemImage: "arrow.down.circle") {
                Task { await environment.downloader.download(item) }
            }
        }
    }

    private func load() async {
        guard let client = environment.jellyfinClient() else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            async let resume = client.resume()
            async let next = client.nextUp()
            async let views = client.views()
            let inProgress = try await resume
            let ids = Set(inProgress.map(\.id))
            continueWatching = inProgress
            // The four next episodes not already in Continue Watching; See All has the rest.
            allNextUp = (try await next).filter { !ids.contains($0.id) }
            nextUp = Array(allNextUp.prefix(4))
            libraries = try await views
            environment.libraries = libraries
            error = nil
        } catch {
            guard !error.isCancellation else { return }
            self.error = error.localizedDescription
            return
        }
        await loadShelves()
    }

    /// Each library's Recently Added shelf. A Japanese Audio Only library fetches more and keeps
    /// the first 12 with Japanese audio.
    private func loadShelves() async {
        guard let client = environment.jellyfinClient() else { return }
        let visible = visibleLibraries, japaneseOnly = environment.japaneseOnlyLibraries
        var fetched: [String: [JellyfinItem]] = [:]
        await withTaskGroup(of: (String, [JellyfinItem]?).self) { group in
            for library in visible {
                let filters = japaneseOnly.contains(library.id)
                group.addTask {
                    (library.id, try? await client.recentlyAdded(libraryId: library.id, limit: filters ? 40 : 12, withStreams: filters))
                }
            }
            for await (id, items) in group {
                if let items { fetched[id] = items }
            }
        }
        for (id, items) in fetched {
            shelves[id] = japaneseOnly.contains(id)
                ? Array(await environment.japaneseAudioOnly(items, client: client).prefix(12)) : items
        }
    }
}

/// A library's newest shows, with its name and "See All" opening the whole library.
private struct LibraryShelf: View {
    let library: JellyfinItem
    let items: [JellyfinItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                NavigationLink(value: library) {
                    Text("\(library.name) · Recently Added").font(.title2.bold()).foregroundStyle(.primary).lineLimit(1)
                }
                .buttonStyle(.plain)
                Spacer()
                NavigationLink("See All", value: library)
                    .accessibilityIdentifier("library.\(library.name)")
            }
            if !items.isEmpty {
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(items) { item in
                            NavigationLink(value: item) { poster(item) }
                                .buttonStyle(.plain)
                                .accessibilityLabel(item.name)
                                .accessibilityIdentifier("home.series.\(item.name)")
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .shelfScrollClip()
            }
        }
    }

    /// A poster with its title under it (two lines kept, so the row lines up), like Yomu's shelves.
    private func poster(_ item: JellyfinItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            JellyfinImage(itemId: item.id, tag: item.imageTags?["Primary"], aspectRatio: 2 / 3, placeholder: "tv")
                .overlay(alignment: .topTrailing) { UnwatchedBadge(userData: item.userData) }
            Text(item.name)
                .font(.caption)
                .lineLimit(2, reservesSpace: true)
                .multilineTextAlignment(.leading)
        }
        .frame(width: 110)
    }
}

/// Shows and movies in every library by name (Jellyfin's search).
struct JellyfinSearchView: View {
    @Environment(PlayerEnvironment.self) private var environment
    @Binding var playback: PlaybackSession?
    @State private var query = ""
    @State private var searching = false
    @State private var results: [JellyfinItem] = []
    @State private var error: String?

    var body: some View {
        List {
            if let error {
                Label(error, systemImage: "wifi.exclamationmark").foregroundStyle(.secondary)
            }
            ForEach(results) { item in
                NavigationLink(value: item) {
                    HStack(spacing: 12) {
                        JellyfinImage(itemId: item.id, tag: item.imageTags?["Primary"], aspectRatio: 2 / 3, placeholder: "tv")
                            .frame(width: 44)
                        VStack(alignment: .leading) {
                            Text(item.name)
                            if let year = item.productionYear {
                                Text(String(year)).font(.caption).foregroundStyle(.secondary)
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
        // The field takes the keyboard as the screen opens.
        .searchable(text: $query, isPresented: $searching, prompt: "Shows and Movies")
        .onAppear { searching = true }
        .navigationTitle("Search")
        .task(id: query) {
            let text = query.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, let client = environment.jellyfinClient() else { results = []; return }
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

/// A Next Up episode: thumbnail, show, and "S3 · E2 · Next".
private struct NextUpRow: View {
    let item: JellyfinItem

    var body: some View {
        HStack(spacing: 14) {
            JellyfinImage(itemId: item.id, tag: item.imageTags?["Primary"], aspectRatio: 16 / 9, placeholder: "film")
                .frame(width: 96)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.seriesName ?? item.name).lineLimit(1)
                Text([item.seasonEpisodeLabel, "Next"].compactMap(\.self).joined(separator: " · "))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
        }
        .padding(.vertical, 10)
        .contentShape(.rect)
    }
}

extension JellyfinItem {
    /// "S2 · E8" (nil for movies).
    var seasonEpisodeLabel: String? {
        guard let episode = indexNumber, seriesName != nil else { return nil }
        return parentIndexNumber.map { "S\($0) · E\(episode)" } ?? "E\(episode)"
    }

    /// "11 min left" once started, else the runtime ("24 min").
    var timeLabel: String? {
        guard let duration, duration > 0 else { return nil }
        if let position = resumePosition {
            return "\(max(1, Int((duration - position) / 60))) min left"
        }
        return "\(max(1, Int(duration / 60))) min"
    }
}

/// A wide thumbnail with the show, episode and progress.
private struct ContinueTile: View {
    @Environment(PlayerEnvironment.self) private var environment
    let item: JellyfinItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            JellyfinImage(itemId: item.id, tag: item.imageTags?["Primary"], aspectRatio: 16 / 9, placeholder: "film")
                .frame(width: 260)
                .overlay(alignment: .bottomLeading) {
                    Image(systemName: "play.fill")
                        .font(.title3)
                        .padding(12)
                        .background(.ultraThinMaterial, in: .circle)
                        .padding(10)
                }
                .overlay(alignment: .bottom) {
                    if let position = item.resumePosition, let duration = item.duration, duration > 0 {
                        ProgressView(value: min(position / duration, 1))
                            .tint(.accentColor)
                            .padding(.horizontal, 2)
                    }
                }
            Text(item.seriesName ?? item.name)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Text([item.seasonEpisodeLabel, item.timeLabel].compactMap(\.self).joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: 260)
    }
}

/// A Jellyfin image fetched with header auth and cached on disk.
struct JellyfinImage: View {
    @Environment(PlayerEnvironment.self) private var environment
    let itemId: String
    var tag: String?
    var aspectRatio: CGFloat
    var placeholder = "photo"
    var type = JellyfinClient.ImageType.primary
    /// Called once the image has loaded (series pages tint their header from it).
    var onImage: ((CGImage) -> Void)?
    @State private var image: CGImage?

    var body: some View {
        Rectangle()
            .fill(.quaternary)
            .aspectRatio(aspectRatio, contentMode: .fit)
            .overlay {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: placeholder)
                        .font(.title)
                        .foregroundStyle(.tertiary)
                }
            }
            .clipShape(.rect(cornerRadius: 8))
            .task(id: "\(itemId)/\(tag ?? "")#\(CoverGeneration.shared.value)") {
                guard let client = environment.jellyfinClient() else { return }
                let request = client.imageRequest(itemId: itemId, type: type, tag: tag, maxWidth: 480)
                await CoverLoader.load(request, maxPixelSize: 480) {
                    image = $0
                    onImage?($0)
                }
            }
    }
}
