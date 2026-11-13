import AppCommon
import Core
import JellyfinKit
import SwiftUI

/// A library's series and movies as a poster grid.
struct JellyfinLibraryView: View {
    @Environment(PlayerEnvironment.self) private var environment
    let library: JellyfinItem
    @State private var items: [JellyfinItem] = []
    @State private var error: String?
    @State private var isLoading = false
    @State private var search = ""
    @State private var shelf = Shelf.all
    /// (checked, to check) while a Japanese Audio Only library's series are checked.
    @State private var audioCheck: (Int, Int)?

    /// All · Unwatched · Downloaded (something of it is on this device).
    enum Shelf: String, CaseIterable {
        case all = "All", unwatched = "Unwatched", downloaded = "Downloaded"
    }

    private var filtered: [JellyfinItem] {
        var items = items
        switch shelf {
        case .all: break
        case .unwatched: items = items.filter { $0.userData?.played != true }
        case .downloaded:
            let downloaded = Set(environment.downloader.records.values.filter { $0.state == .done }.compactMap(\.seriesKey))
            items = items.filter { downloaded.contains($0.id) }
        }
        return search.isEmpty ? items : items.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        ScrollView {
            if let error {
                Label(error, systemImage: "wifi.exclamationmark")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            }
            Picker("Show", selection: $shelf) {
                ForEach(Shelf.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .accessibilityIdentifier("library.filter")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110, maximum: 180), spacing: 16, alignment: .top)], spacing: 20) {
                ForEach(filtered) { item in
                    NavigationLink(value: item) {
                        VStack(alignment: .leading, spacing: 4) {
                            JellyfinImage(itemId: item.id, tag: item.imageTags?["Primary"], aspectRatio: 2 / 3, placeholder: "tv")
                                .overlay(alignment: .topTrailing) { UnwatchedBadge(userData: item.userData) }
                            // Two lines kept for every title, so posters in a row line up.
                            Text(item.name)
                                .font(.caption)
                                .lineLimit(2, reservesSpace: true)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("series.\(item.name)")
                }
            }
            .padding()
        }
        .overlay {
            if let (done, total) = audioCheck {
                ProgressView("Checking audio… \(done) of \(total)", value: Double(done), total: Double(total))
                    .padding(40)
            } else if items.isEmpty && isLoading {
                ProgressView()
            } else if items.isEmpty && !isLoading && japaneseOnly && error == nil {
                ContentUnavailableView("No Japanese Audio", systemImage: "waveform",
                                       description: Text("Nothing in this library has a Japanese audio track."))
            } else if filtered.isEmpty && search.isEmpty && !items.isEmpty {
                ContentUnavailableView(shelf == .downloaded ? "Nothing Downloaded" : "All Watched",
                                       systemImage: shelf == .downloaded ? "arrow.down.circle" : "checkmark.circle")
            }
        }
        #if os(iOS)
        // Always showing: hidden until a pull-down, the filter looked missing.
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Filter")
        #else
        .searchable(text: $search, prompt: "Filter")
        #endif
        .navigationTitle(library.name)
        .navigationSubtitle(japaneseOnly ? "Japanese audio only" : "")
        .refreshable {
            CoverLoader.recheck()
            await load()
        }
        .task(id: japaneseOnly) { await load() }
    }

    private var japaneseOnly: Bool { environment.japaneseOnlyLibraries.contains(library.id) }

    private func load() async {
        guard let client = environment.jellyfinClient() else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let all = try await client.libraryItems(libraryId: library.id, withStreams: japaneseOnly)
            if japaneseOnly {
                items = await environment.japaneseAudioOnly(all, client: client) { done, total in
                    audioCheck = total > 0 && done < total ? (done, total) : nil
                }
                audioCheck = nil
            } else {
                items = all
            }
            error = nil
        } catch {
            guard !error.isCancellation else { return }
            self.error = error.localizedDescription
        }
    }
}

struct UnwatchedBadge: View {
    let userData: JellyfinUserData?

    var body: some View {
        if userData?.played == true {
            Image(systemName: "checkmark.circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .tint)
                .padding(6)
        } else if let count = userData?.unplayedItemCount, count > 0 {
            Text("\(count)")
                .font(.caption2.weight(.bold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.tint, in: .capsule)
                .foregroundStyle(.white)
                .padding(6)
        }
    }
}

/// A series' seasons and episodes (or a movie, playable directly).
struct SeriesView: View {
    @Environment(PlayerEnvironment.self) private var environment
    let series: JellyfinItem
    @Binding var playback: PlaybackSession?
    @State private var details: JellyfinItem?
    @State private var seasons: [JellyfinItem] = []
    @State private var seasonId: String?
    @State private var episodes: [JellyfinItem] = []
    /// Where watching picks up (Jellyfin's Next Up for this series).
    @State private var next: JellyfinItem?
    @State private var savedLines: Set<String> = []
    @State private var tint: Color?
    @State private var error: String?
    @State private var isLoading = false
    @State private var confirmsSeasonDownload = false

    /// Episodes in this season that aren't downloaded or downloading.
    private var notDownloaded: [JellyfinItem] {
        episodes.filter { environment.downloader.records[$0.id] == nil }
    }

    private var item: JellyfinItem { details ?? series }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                playButton
                if let error {
                    Label(error, systemImage: "wifi.exclamationmark")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if let overview = item.overview, !overview.isEmpty {
                    ExpandableText(overview)
                }
                if seasons.count > 1 {
                    ChipRow(seasons) { season in
                        Button(season.name) { seasonId = season.id }
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                            .tint(season.id == seasonId ? .accentColor : .secondary)
                            .accessibilityAddTraits(season.id == seasonId ? .isSelected : [])
                    }
                    .accessibilityIdentifier("series.season")
                }
                if !episodes.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(Array(episodes.enumerated()), id: \.element.id) { offset, episode in
                            if offset > 0 { Divider().padding(.leading, 44) }
                            HStack(spacing: 10) {
                                Button {
                                    playback = PlaybackSession(item: episode, following: episodes[(offset + 1)...].map(\.id))
                                } label: {
                                    EpisodeRow(episode: episode, progress: localProgress(episode), hasLines: savedLines.contains(episode.id))
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("episode.\(episode.indexNumber ?? offset + 1)")
                                EpisodeDownloadButton(item: episode)
                            }
                            .padding(.vertical, 10)
                        }
                    }
                    .padding(.horizontal)
                    .background(.background.secondary, in: .rect(cornerRadius: 16))
                }
            }
            .padding()
        }
        .background(alignment: .top) {
            TintedHeaderBackground(color: tint).frame(height: 420)
        }
        .overlay {
            if episodes.isEmpty && isLoading { ProgressView() }
        }
        .navigationTitle(series.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            if !episodes.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Menu("Downloads", systemImage: "arrow.down.circle") {
                        Button("Download \(notDownloaded.count) Episodes", systemImage: "arrow.down.circle") {
                            confirmsSeasonDownload = true
                        }
                        .disabled(notDownloaded.isEmpty)
                        Button("Delete Downloads", systemImage: "trash", role: .destructive) {
                            let records = episodes.compactMap { environment.downloader.records[$0.id] }
                            Task { for record in records { await environment.downloader.delete(record) } }
                        }
                        .disabled(!episodes.contains { environment.downloader.records[$0.id] != nil })
                    }
                    .accessibilityIdentifier("series.downloads")
                }
            }
        }
        .confirmationDialog("Download \(notDownloaded.count) episodes?", isPresented: $confirmsSeasonDownload, titleVisibility: .visible) {
            Button("Download") {
                let items = notDownloaded
                Task { await environment.downloader.download(items) }
            }
        } message: {
            Text("Each is the original file, often 1–2 GB. They wait for Wi-Fi unless cellular downloads are on in Settings.")
        }
        .refreshable { await loadEpisodes() }
        .task { await loadSeasons() }
        .task { await loadDetails() }
        .onChange(of: seasonId) { Task { await loadEpisodes() } }
        .onReceive(NotificationCenter.default.publisher(for: .playbackDidClose)) { _ in
            Task {
                await loadEpisodes()
                await loadDetails()
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .bottom, spacing: 16) {
            JellyfinImage(itemId: series.id, tag: series.imageTags?["Primary"], aspectRatio: 2 / 3, placeholder: "tv") { image in
                tint = CoverTint.color(of: image)
            }
            .frame(width: 130)
            .shadow(radius: 8, y: 4)
            VStack(alignment: .leading, spacing: 4) {
                Text(series.name).font(.title2.bold())
                Text(facts).font(.subheadline).foregroundStyle(.secondary)
                    .accessibilityIdentifier("series.facts")
            }
        }
    }

    /// "2023 · 3 seasons · 35 episodes" (or the year and runtime of a movie).
    private var facts: String {
        var parts: [String] = []
        if let year = item.productionYear { parts.append(String(year)) }
        if series.type == "Movie" {
            if let duration = item.duration { parts.append("\(Int(duration / 60)) min") }
        } else {
            let seasonCount = seasons.isEmpty ? item.childCount ?? 0 : seasons.count
            if seasonCount > 0 { parts.append("\(seasonCount) \(seasonCount == 1 ? "season" : "seasons")") }
            if let count = item.recursiveItemCount, count > 0 { parts.append("\(count) \(count == 1 ? "episode" : "episodes")") }
        }
        return parts.joined(separator: " · ")
    }

    /// "Resume · S2 · E3", "Play · S1 · E1", or Play and download for a movie.
    @ViewBuilder private var playButton: some View {
        HStack(spacing: 12) {
            let target = series.type == "Movie" ? series : next ?? episodes.first
            if let target {
                Button {
                    if target.id == series.id {
                        playback = PlaybackSession(item: series)
                    } else {
                        let following = episodes.firstIndex { $0.id == target.id }.map { episodes[($0 + 1)...].map(\.id) } ?? []
                        playback = PlaybackSession(item: target, following: following)
                    }
                } label: {
                    Label {
                        Text(playTitle(target)).lineLimit(1)
                    } icon: {
                        Image(systemName: "play.fill")
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .accessibilityIdentifier("series.play")
            }
            if series.type == "Movie" {
                EpisodeDownloadButton(item: series)
            }
        }
    }

    private func playTitle(_ target: JellyfinItem) -> String {
        let verb = target.resumePosition != nil ? "Resume" : "Play"
        return [verb, target.seasonEpisodeLabel].compactMap(\.self).joined(separator: " · ")
    }

    /// The device's own progress, newer than Jellyfin's when watched offline.
    private func localProgress(_ episode: JellyfinItem) -> Double? {
        guard let local = try? environment.watchProgress.progress(itemId: episode.id), local.duration > 0 else { return nil }
        return min(local.position / local.duration, 1)
    }

    // MARK: Loading

    private func loadDetails() async {
        savedLines = (try? environment.transcripts.savedItemIds()) ?? []
        guard let client = environment.jellyfinClient() else { return }
        details = try? await client.item(id: series.id)
        if series.type == "Series" {
            next = (try? await client.nextUp(seriesId: series.id, limit: 1))?.first
        }
    }

    private func loadSeasons() async {
        guard series.type == "Series", let client = environment.jellyfinClient() else { return }
        guard seasons.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            seasons = try await client.seasons(seriesId: series.id)
            // Open the first season with something left to watch; Specials (season 0, listed
            // first) only when there are no others.
            let regular = seasons.filter { $0.indexNumber != 0 }
            let pool = regular.isEmpty ? seasons : regular
            seasonId = (pool.first { $0.userData?.played != true } ?? pool.first)?.id
            if seasons.isEmpty { await loadEpisodes() }
        } catch {
            guard !error.isCancellation else { return }
            self.error = error.localizedDescription
        }
    }

    private func loadEpisodes() async {
        guard series.type == "Series", let client = environment.jellyfinClient() else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            episodes = try await client.episodes(seriesId: series.id, seasonId: seasonId)
            error = nil
        } catch {
            guard !error.isCancellation else { return }
            self.error = error.localizedDescription
        }
    }
}

/// An episode: watch state on the left (circle, ring, check), its thumbnail (dimmed once
/// watched), title, time left or runtime, and a Lines tag when its subtitles are saved.
private struct EpisodeRow: View {
    let episode: JellyfinItem
    /// The device's own progress (0…1), when it has one.
    var progress: Double?
    var hasLines = false

    /// "3. Name"; a special (season 0) by its name alone, without the "S1 " some libraries
    /// put in front of it.
    static func title(_ episode: JellyfinItem) -> String {
        guard episode.parentIndexNumber != 0 else {
            return episode.name.replacingOccurrences(of: #"^S\d+\s+"#, with: "", options: .regularExpression)
        }
        return episode.indexNumber.map { "\($0). \(episode.name)" } ?? episode.name
    }

    private var fraction: Double {
        if let position = episode.resumePosition, let duration = episode.duration, duration > 0 { return min(position / duration, 1) }
        return progress ?? 0
    }

    private var watched: Bool { episode.userData?.played == true || (progress ?? 0) > 0.97 }

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if watched {
                    Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(.tint)
                } else if fraction > 0 {
                    ProgressRing(fraction: fraction).padding(3)
                } else {
                    Circle().stroke(.tertiary, lineWidth: 2).padding(3)
                }
            }
            .frame(width: 26, height: 26)
            .accessibilityLabel(watched ? "Watched" : fraction > 0 ? "Partly watched" : "Not watched")
            JellyfinImage(itemId: episode.id, tag: episode.imageTags?["Primary"], aspectRatio: 16 / 9, placeholder: "film")
                .frame(width: 112)
                .overlay(alignment: .bottom) {
                    if !watched, fraction > 0 {
                        ProgressView(value: fraction).tint(.accentColor).padding(.horizontal, 2)
                    }
                }
                .opacity(watched ? 0.55 : 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(Self.title(episode))
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                HStack(spacing: 6) {
                    if let time = episode.timeLabel { Text(time) }
                    if hasLines {
                        Label("Lines", systemImage: "text.quote")
                            .foregroundStyle(.tint)
                            .accessibilityIdentifier("episode.lines")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if episode.mediaStreams != nil && episode.japaneseSubtitle == nil {
                    Label("No Japanese subtitles", systemImage: "captions.bubble")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("episode.noJapanese")
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(.rect)
    }
}
