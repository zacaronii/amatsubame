import AppCommon
import AudiobookshelfKit
import SwiftUI

enum ListenRoute: Hashable {
    case library
    /// One library, opened from the sidebar.
    case only(AudiobookshelfLibrary)
    case show(String)
    case book(String)
}

/// The Listen tab (K1): today's numbers, Continue Listening, New Episodes, and the Library. On
/// a wide screen the home stays on the left and shows open on the right.
struct ListenView: View {
    /// New Episodes on the home screen; See All has the rest.
    static let newEpisodesShown = 6

    @Environment(KikuEnvironment.self) private var environment
    @Environment(\.scenePhase) private var scenePhase
    @State private var today: TodaySummary?
    @State private var query = ""
    @State private var path: [ListenRoute] = []
    /// Bumped when the Listen tab is tapped again.
    var reset = 0

    private var library: PodcastLibrary { environment.library }

    var body: some View {
        WideSplitStack(path: $path) {
            Group {
                if !environment.common.accountsLoaded {
                    ProgressView()
                } else if environment.common.serverAccounts[.audiobookshelf] == nil {
                    ContentUnavailableView {
                        Label("Connect Audiobookshelf", systemImage: "headphones")
                    } description: {
                        Text("Sign in to your Audiobookshelf server in Settings to see your podcasts.")
                    } actions: {
                        Button("Open Settings") { environment.selectedTab = .settings }
                            .buttonStyle(.borderedProminent)
                    }
                } else if !query.isEmpty {
                    SearchResults(query: query)
                } else {
                    home
                }
            }
            .navigationTitle("Listen")
            .searchable(text: $query, prompt: "Shows and episodes")
        } destination: { route in
            switch route {
            case .library: LibraryView()
            case .only(let library): LibraryView(only: library)
            case .show(let id): ShowView(itemId: id)
            case .book(let id): BookView(itemId: id)
            }
        } empty: {
            // Wide, nothing picked yet: the library beside the home screen.
            LibraryView()
        }
        .onChange(of: reset) {
            path = []
            query = ""
        }
        .onChange(of: environment.requestedLibrary, initial: true) { _, library in
            guard let library else { return }
            environment.requestedLibrary = nil
            query = ""
            path = [.only(library)]
        }
        .task(id: environment.common.serverAccounts[.audiobookshelf]?.baseURL) {
            if library.shows.isEmpty { await library.refresh() }
        }
        .onAppear { loadToday() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { loadToday() }
        }
        .onChange(of: environment.playback?.audio.isPlaying) {
            today = TodaySummary.load(kind: .listening, environment: environment.common)
        }
    }

    /// At once from the device, then with the mining deck asked for again.
    private func loadToday() {
        today = TodaySummary.load(kind: .listening, environment: environment.common)
        Task { today = await TodaySummary.refreshed(kind: .listening, environment: environment.common) }
    }

    private var home: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if library.isOffline {
                    Label("Can't reach Audiobookshelf. Your library is from the last time it loaded, and downloaded episodes play.",
                          systemImage: "wifi.slash")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("listen.offline")
                }
                if let today {
                    TodayRow(kind: .listening, today: today) { environment.selectedTab = .stats }
                }
                if !library.continueListening.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Continue Listening").font(.title2.bold())
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(alignment: .top, spacing: 14) {
                                ForEach(library.continueListening) { entry in
                                    ContinueCard(entry: entry)
                                }
                            }
                        }
                        .shelfScrollClip()
                    }
                }
                if library.isOffline, !environment.downloadedEntries.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Downloaded").font(.title2.bold())
                        EpisodeList(entries: environment.downloadedEntries)
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("New Episodes").font(.title2.bold())
                        Spacer()
                        NavigationLink("Library", value: ListenRoute.library)
                            .accessibilityIdentifier("listen.library")
                    }
                    if library.newEpisodes.isEmpty {
                        Group {
                            if library.isLoading {
                                ProgressView().frame(maxWidth: .infinity)
                            } else if let error = library.error, !library.isOffline {
                                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                            } else if !library.isOffline {
                                Text("You're up to date.").foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical)
                    } else {
                        EpisodeList(entries: Array(library.newEpisodes.prefix(Self.newEpisodesShown)))
                        if library.newEpisodes.count > Self.newEpisodesShown {
                            NavigationLink {
                                ScrollView { EpisodeList(entries: library.newEpisodes).padding() }
                                    .navigationTitle("New Episodes")
                            } label: {
                                Text("See All \(library.newEpisodes.count)").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                            .accessibilityIdentifier("newEpisodes.seeAll")
                        }
                    }
                }
            }
            .padding()
        }
        .refreshable { await library.refresh() }
    }
}

/// Episode rows on a rounded background (New Episodes, and Downloaded when offline).
private struct EpisodeList: View {
    let entries: [EpisodeEntry]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                if index > 0 { Divider().padding(.leading, 68) }
                NewEpisodeRow(entry: entry)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(.background.secondary, in: .rect(cornerRadius: 20))
    }
}

/// A Continue Listening card: square artwork with progress, the title and the time left.
private struct ContinueCard: View {
    @Environment(KikuEnvironment.self) private var environment
    let entry: EpisodeEntry

    var body: some View {
        Button { environment.play(entry) } label: {
            VStack(alignment: .leading, spacing: 6) {
                ShowCover(itemId: entry.itemId, cornerRadius: 16)
                    .overlay(alignment: .bottom) {
                        GeometryReader { proxy in
                            Capsule().fill(.white.opacity(0.35)).frame(height: 4)
                                .overlay(alignment: .leading) {
                                    Capsule().fill(.tint).frame(width: proxy.size.width * entry.fraction, height: 4)
                                }
                        }
                        .frame(height: 4)
                        .padding(10)
                    }
                Text(entry.episode.title).font(.subheadline).lineLimit(2).multilineTextAlignment(.leading)
                Text("\(entry.timeLeft.lengthText) left").font(.footnote).foregroundStyle(.secondary)
            }
            .frame(width: 160)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("listen.continue")
    }
}

/// Shows and episodes whose titles match (K1's search; transcript search lives in Marks).
private struct SearchResults: View {
    @Environment(KikuEnvironment.self) private var environment
    let query: String

    var body: some View {
        let library = environment.library
        let shows = (library.shows + library.books).filter { $0.title.localizedCaseInsensitiveContains(query) }
        let episodes = (library.newEpisodes + library.showEpisodes.values.flatMap { $0 }.map { library.entry($0) })
            .filter { $0.episode.title.localizedCaseInsensitiveContains(query) }
        let unique = Dictionary(episodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values
            .sorted { ($0.episode.publishedAt ?? 0) > ($1.episode.publishedAt ?? 0) }
        List {
            if !shows.isEmpty {
                Section("Shows and Books") {
                    ForEach(shows) { show in
                        NavigationLink(value: show.isBook ? ListenRoute.book(show.id) : ListenRoute.show(show.id)) {
                            HStack(spacing: 12) {
                                ShowCover(itemId: show.id).frame(width: 44, height: 44)
                                Text(show.title)
                            }
                        }
                    }
                }
            }
            if !unique.isEmpty {
                Section("Episodes") {
                    ForEach(unique) { NewEpisodeRow(entry: $0) }
                }
            }
            if shows.isEmpty && unique.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
    }
}
