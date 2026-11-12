import AppCommon
import Core
import JellyfinKit
import SwiftUI

/// What the Lines tab opens: an episode's subtitles, or another device's live feed.
enum LinesRoute: Hashable {
    case transcript(TranscriptRoute)
    case live(LiveRoute)
}

/// The Lines tab: what's been watched (any device), each episode's subtitles as a
/// readable feed, and search across every saved transcript. On a wide screen the list stays
/// on the left and the episode opens on the right.
struct LinesView: View {
    /// Groups of one show opened in the history.
    @State private var expanded: Set<String> = []
    @Environment(PlayerEnvironment.self) private var environment
    @Environment(CommonEnvironment.self) private var common
    @State private var history: LinesHistoryModel?
    @State private var live: LiveSessionsModel?
    @State private var query = ""
    @State private var results: [TranscriptSearchGroup] = []
    @State private var playback: PlaybackSession?
    @State private var path: [LinesRoute] = []
    /// Bumped when the Lines tab is tapped again.
    var reset = 0

    var body: some View {
        // The right side shows one episode at a time: a pick replaces it (no back button).
        WideSplitStack(path: $path, showsBack: false) {
            Group {
                if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                    searchResults
                } else if let history {
                    WideSplitReader { wide in historyList(history, wide: wide) }
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Lines")
            .searchable(text: $query, prompt: "Search saved subtitles")
        } destination: { route in
            switch route {
            case .transcript(let route): TranscriptView(route: route, playback: $playback)
            case .live(let route): LiveFeedView(route: route)
            }
        } empty: {
            // Wide, nothing picked yet: the latest episode.
            if let entry = history?.entries.first {
                TranscriptView(route: Self.route(entry), playback: $playback)
            } else {
                ContentUnavailableView("Choose an Episode", systemImage: "text.quote")
            }
        }
        .playbackPresentation($playback)
        .onChange(of: reset) {
            path = []
            query = ""
        }
        .task(id: query) {
            // Debounced; the store reads are local and quick.
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            results = (try? environment.transcripts.search(query)) ?? []
        }
        .task(id: common.serverAccounts[.jellyfin]?.userId) {
            let model = history ?? LinesHistoryModel(environment: environment)
            history = model
            await model.refresh()
        }
        .task(id: common.serverAccounts[.jellyfin]?.userId) {
            // Other devices playing something; polled while Lines is showing.
            let model = live ?? LiveSessionsModel(environment: environment)
            live = model
            await model.poll()
        }
        .onChange(of: environment.hiddenLibraries) {
            Task { await history?.refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .playbackDidClose)) { _ in
            Task { await history?.refresh() }
        }
    }

    // MARK: History

    private func episodeLink(_ entry: LinesHistoryModel.Entry, _ history: LinesHistoryModel, wide: Bool) -> some View {
        NavigationLink(value: LinesRoute.transcript(Self.route(entry))) {
            HistoryRow(entry: entry)
        }
        .listRowBackground(isSelected(entry, history, wide: wide) ? Color.accentColor.opacity(0.18) : nil)
        .accessibilityIdentifier("lines.episode")
        .onAppear { loadMoreIfLast([entry], history) }
    }

    /// Side by side, the episode showing on the right (the latest until one is picked).
    private func isSelected(_ entry: LinesHistoryModel.Entry, _ history: LinesHistoryModel, wide: Bool) -> Bool {
        guard wide else { return false }
        switch path.first {
        case .transcript(let route)?: return route.itemId == entry.id
        case .live?: return false
        case nil: return entry.id == history.entries.first?.id
        }
    }

    static func route(_ entry: LinesHistoryModel.Entry) -> TranscriptRoute {
        TranscriptRoute(itemId: entry.id, title: [entry.show, entry.detail].filter { !$0.isEmpty }.joined(separator: " · "))
    }

    private func loadMoreIfLast(_ run: [LinesHistoryModel.Entry], _ history: LinesHistoryModel) {
        if run.contains(where: { $0.id == history.entries.last?.id }), history.canLoadMore {
            Task { await history.loadMore() }
        }
    }

    private func historyList(_ history: LinesHistoryModel, wide: Bool) -> some View {
        List {
            if let error = history.error {
                Label(error, systemImage: "wifi.exclamationmark")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let sessions = live?.sessions, !sessions.isEmpty {
                Section("Watching Now") {
                    ForEach(sessions) { session in
                        NavigationLink(value: LinesRoute.live(LiveRoute(sessionId: session.id))) {
                            LiveSessionRow(session: session)
                        }
                        .accessibilityIdentifier("lines.live")
                    }
                }
            }
            Section(history.entries.isEmpty ? "" : "Watched") {
                // Still a history: only episodes of one show watched back to back are grouped,
                // and a group opens to them in the order they were watched.
                ForEach(LinesHistoryModel.runs(history.entries), id: \.first!.id) { run in
                    if run.count == 1 {
                        episodeLink(run[0], history, wide: wide)
                    } else {
                        DisclosureGroup(isExpanded: Binding(get: { expanded.contains(run[0].id) },
                                                            set: { if $0 { expanded.insert(run[0].id) } else { expanded.remove(run[0].id) } })) {
                            ForEach(run) { entry in episodeLink(entry, history, wide: wide) }
                        } label: {
                            HistoryRow(entry: run[0], episodes: run.count)
                        }
                        .listRowBackground(!expanded.contains(run[0].id) && run.contains { isSelected($0, history, wide: wide) }
                                           ? Color.accentColor.opacity(0.18) : nil)
                        .accessibilityIdentifier("lines.group")
                        .onAppear { loadMoreIfLast(run, history) }
                    }
                }
            }
        }
        .overlay {
            if history.entries.isEmpty && live?.sessions.isEmpty != false {
                if history.isLoading {
                    ProgressView()
                } else {
                    ContentUnavailableView(
                        "Nothing Watched Yet", systemImage: "text.quote",
                        description: Text("Episodes you watch in Jellyfin, on any device, show up here with their Japanese subtitles.")
                    )
                    .accessibilityIdentifier("lines.empty")
                }
            }
        }
        .refreshable { await history.refresh() }
    }

    // MARK: Search

    private var searchResults: some View {
        List {
            ForEach(results) { group in
                Section(TranscriptView.title(group.transcript)) {
                    ForEach(group.lines, id: \.cue) { line in
                        NavigationLink(value: LinesRoute.transcript(TranscriptRoute(itemId: group.transcript.itemId,
                                                                                    title: TranscriptView.title(group.transcript), focusCue: line.cue))) {
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(TranscriptView.timestamp(line.start))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                Text(Self.highlighted(TappableLine.sentence(line.text), query))
                            }
                        }
                        .accessibilityIdentifier("lines.result")
                    }
                }
            }
        }
        .overlay {
            if results.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
    }

    /// The line with each occurrence of `query` in bold and tinted.
    static func highlighted(_ text: String, _ query: String) -> AttributedString {
        var attributed = AttributedString(text)
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return attributed }
        var searchStart = attributed.startIndex
        // Like the search itself: any case, and full- or half-width letters.
        while let range = attributed[searchStart...].range(of: needle, options: [.caseInsensitive, .widthInsensitive]) {
            attributed[range].foregroundColor = .accentColor
            attributed[range].inlinePresentationIntent = .stronglyEmphasized
            searchStart = range.upperBound
        }
        return attributed
    }
}

private struct HistoryRow: View {
    let entry: LinesHistoryModel.Entry
    /// For a group: how many episodes of the show were watched back to back.
    var episodes = 1

    var body: some View {
        HStack(spacing: 12) {
            JellyfinImage(itemId: entry.id, tag: entry.imageTag, aspectRatio: 16 / 9, placeholder: "film")
                .frame(width: 96)
                .overlay(alignment: .bottom) {
                    if let progress = entry.progress {
                        ProgressView(value: min(progress, 1)).tint(.white).padding(3)
                    }
                }
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.show)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if episodes > 1 {
                    Text("\(episodes) episodes · latest \(entry.detail)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if !entry.detail.isEmpty {
                    Text(entry.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if entry.hasJapanese == false {
                    Label("No Japanese subtitles", systemImage: "captions.bubble")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                } else if entry.isSaved {
                    Label("Saved", systemImage: "text.bubble")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

/// Another device's playback: what it's playing and where.
private struct LiveSessionRow: View {
    let session: JellyfinSession

    var body: some View {
        HStack(spacing: 12) {
            if let item = session.nowPlayingItem {
                JellyfinImage(itemId: item.id, tag: item.imageTags?["Primary"], aspectRatio: 16 / 9, placeholder: "tv")
                    .frame(width: 96)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(session.nowPlayingItem.map { $0.seriesName ?? $0.name } ?? "")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if let item = session.nowPlayingItem, item.seriesName != nil {
                    Text([item.episodeLabel, item.name].compactMap(\.self).joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Label("\(session.deviceName ?? "Another device") · \(session.isPaused ? "Paused" : "Playing")",
                      systemImage: session.isPaused ? "pause.circle" : "dot.radiowaves.left.and.right")
                    .font(.caption2)
                    .foregroundStyle(.tint)
            }
            Spacer(minLength: 0)
        }
    }
}
