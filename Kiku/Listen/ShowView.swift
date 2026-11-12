import AppCommon
import AudiobookshelfKit
import SwiftUI

/// A show page (K3): tinted header, Resume or Play latest, the description, and its episodes.
struct ShowView: View {
    @Environment(KikuEnvironment.self) private var environment
    let itemId: String

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", unplayed = "Unplayed", downloaded = "Downloaded"
        var id: Self { self }
    }

    @State private var filter = Filter.all
    @State private var tint: Color?
    /// The show's episodes have come back from the server (or failed to): only then is an
    /// empty list news.
    @State private var loaded = false

    private var show: AudiobookshelfItem? { environment.library.shows.first { $0.id == itemId } }
    private var entries: [EpisodeEntry] {
        (environment.library.showEpisodes[itemId] ?? []).map { environment.library.entry($0, showTitle: show?.title ?? environment.library.showTitle(itemId)) }
    }

    private var filtered: [EpisodeEntry] {
        switch filter {
        case .all: entries
        case .unplayed: entries.filter { !$0.isFinished }
        case .downloaded: entries.filter { environment.localAudioFile($0.id) != nil }
        }
    }

    /// The most recently listened-to unfinished episode, else the newest.
    private var primary: (title: String, entry: EpisodeEntry)? {
        let started = entries.filter { $0.isStarted && !$0.isFinished }.max { ($0.progress?.lastUpdate ?? 0) < ($1.progress?.lastUpdate ?? 0) }
        if let started { return ("Resume · \(started.shortName)", started) }
        return entries.first.map { ("Play Latest", $0) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .bottom, spacing: 16) {
                    ShowCover(itemId: itemId, cornerRadius: 16) { image in tint = CoverTint.color(of: image) }
                        .frame(width: 130, height: 130)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(show?.title ?? environment.library.showTitle(itemId)).font(.title.bold()).lineLimit(3)
                        Text("Podcast · \(show?.media.numEpisodes ?? entries.count) episodes").foregroundStyle(.secondary)
                    }
                }
                if let primary {
                    Button { environment.play(primary.entry) } label: {
                        Label(primary.title, systemImage: "play.fill")
                            .font(.headline)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .foregroundStyle(Color(red: 0x3A / 255, green: 0x1A / 255, blue: 0x05 / 255))
                    .accessibilityIdentifier("show.primary")
                }
                if let description = show?.media.metadata.description, !description.isEmpty {
                    ExpandableText(PlainText.from(html: description))
                }
                ChipRow(Filter.allCases) { item in
                    Button(item.rawValue) { filter = item }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .tint(item == filter ? Color("AccentColor") : .secondary)
                        .accessibilityAddTraits(item == filter ? .isSelected : [])
                }
                if !filtered.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(Array(filtered.enumerated()), id: \.element.id) { index, entry in
                            if index > 0 { Divider().padding(.leading, 40) }
                            ShowEpisodeRow(entry: entry)
                        }
                    }
                    .padding(.horizontal)
                    .background(.background.secondary, in: .rect(cornerRadius: 20))
                } else if loaded {
                    Text(filter == .downloaded ? "No downloaded episodes." : filter == .unplayed ? "No unplayed episodes." : "No episodes.")
                        .foregroundStyle(.secondary).frame(maxWidth: .infinity).padding()
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding()
                }
            }
            .padding()
        }
        .background(alignment: .top) {
            TintedHeaderBackground(color: tint).frame(height: 420)
        }
        .overlay {
            if environment.library.showEpisodes[itemId] == nil { ProgressView() }
        }
        .navigationTitle(show?.title ?? environment.library.showTitle(itemId))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: itemId) {
            await environment.library.loadShow(itemId)
            loaded = true
        }
        .refreshable { await environment.library.loadShow(itemId) }
    }
}

extension EpisodeEntry {
    /// "#312" when the episode has a number, else its title.
    var shortName: String {
        if let number = episode.episode, !number.isEmpty { return "#\(number)" }
        if let match = episode.title.firstMatch(of: /^#?\d+/) { return String(match.output).hasPrefix("#") ? String(match.output) : "#\(match.output)" }
        return episode.title
    }
}
