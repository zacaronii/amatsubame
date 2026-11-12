import Core
import JellyfinKit
import JimakuKit
import Observation
import PlayerKit
import SwiftUI

/// A subtitle file chosen on Jimaku, downloaded and read.
struct PickedSubtitle {
    var fileName: String
    var data: Data
    var format: SubtitleFile.Format
    var track: SubtitleTrack
}

/// Finds Japanese subtitles for an episode on Jimaku: the show (by its AniList id when
/// Jellyfin knows the AniDB one, else by name), then that episode's files.
@MainActor @Observable
final class SubtitleSearchModel {
    enum Stage: Equatable {
        case needsKey
        case loading
        case entries
        case files(JimakuEntry)
        /// A zip's subtitle files.
        case archive(JimakuEntry, JimakuFile)
    }

    private(set) var stage = Stage.loading
    var query: String
    private(set) var entries: [JimakuEntry] = []
    private(set) var files: [JimakuFile] = []
    private(set) var members: [JimakuArchive.Member] = []
    /// Every file of the show, not just this episode's.
    private(set) var showsAllFiles = false
    private(set) var isWorking = false
    private(set) var error: String?

    let episode: Int?
    @ObservationIgnored private let item: JellyfinItem?
    @ObservationIgnored private let environment: PlayerEnvironment
    @ObservationIgnored private let client: JimakuClient?

    init(item: JellyfinItem?, environment: PlayerEnvironment) {
        self.item = item
        self.environment = environment
        client = environment.jimakuClient()
        episode = item?.isEpisode == true ? item?.indexNumber : nil
        query = item?.seriesName ?? item?.name ?? ""
        if client == nil { stage = .needsKey }
    }

    /// The show by id when possible, else by name.
    func start() async {
        guard let client else { return }
        await working {
            if let anilist = await anilistId(), let found = try? await client.search(anilistId: anilist), !found.isEmpty {
                entries = found
            } else {
                entries = try await client.search(query: query)
            }
            // One match: go straight to its files.
            if entries.count == 1 { try await loadFiles(entries[0]) } else { stage = .entries }
        }
    }

    func search() async {
        guard let client, !query.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        await working {
            entries = try await client.search(query: query)
            stage = .entries
        }
    }

    func open(_ entry: JimakuEntry) async {
        showsAllFiles = false
        await working { try await loadFiles(entry) }
    }

    func showAllFiles() async {
        guard case .files(let entry) = stage, let client else { return }
        await working {
            files = try await client.files(entryId: entry.id)
            showsAllFiles = true
        }
    }

    func back() {
        switch stage {
        case .archive(let entry, _): stage = .files(entry)
        case .files: stage = .entries
        default: break
        }
    }

    /// Downloads and reads a file; a zip opens its list instead (nil returned).
    func pick(_ file: JimakuFile) async -> PickedSubtitle? {
        guard let client, case .files(let entry) = stage else { return nil }
        var picked: PickedSubtitle?
        await working {
            let data = try await client.download(file)
            switch JimakuFileKind(fileName: file.name) {
            case .zip:
                members = try JimakuArchive.subtitles(in: data)
                if members.isEmpty { throw ConnectionError.message("There are no subtitle files in this zip.") }
                stage = .archive(entry, file)
            case .subtitle:
                picked = try Self.read(name: file.name, data: data)
            case .unsupported(let kind):
                throw ConnectionError.message("The app can't open \(kind) files.")
            }
        }
        return picked
    }

    func pick(_ member: JimakuArchive.Member) -> PickedSubtitle? {
        do {
            return try Self.read(name: member.name, data: member.data)
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    static func read(name: String, data: Data) throws -> PickedSubtitle {
        guard let text = SubtitleFile.decode(data), let format = SubtitleFile.format(fileName: name, text: text) else {
            throw ConnectionError.message("This file isn't a subtitle the app can read.")
        }
        let track = SubtitleFile.track(text, format: format)
        guard !track.cues.isEmpty else { throw ConnectionError.message("This file has no dialogue lines.") }
        return PickedSubtitle(fileName: name, data: data, format: format, track: track)
    }

    private func loadFiles(_ entry: JimakuEntry) async throws {
        guard let client else { return }
        files = try await client.files(entryId: entry.id, episode: episode)
        showsAllFiles = episode == nil
        if files.isEmpty, episode != nil {
            // Jimaku couldn't tell episodes apart from the names: show everything.
            files = try await client.files(entryId: entry.id)
            showsAllFiles = true
        }
        stage = .files(entry)
    }

    /// The season's (else the show's) AniDB id, mapped to AniList.
    private func anilistId() async -> Int? {
        guard let item, let jellyfin = environment.jellyfinClient() else { return nil }
        var anidb: Int?
        for id in [item.seasonId, item.seriesId].compactMap(\.self) where anidb == nil {
            anidb = try? await jellyfin.item(id: id).anidbId
        }
        guard let anidb else { return nil }
        return try? await environment.animeIdMapper.anilistId(anidbId: anidb)
    }

    private func working(_ body: () async throws -> Void) async {
        isWorking = true
        error = nil
        defer { isWorking = false }
        do {
            try await body()
        } catch ConnectionError.unauthorized {
            error = "Jimaku didn't accept the API key. Check it in Settings → Jimaku."
        } catch {
            self.error = error.localizedDescription
        }
        if stage == .loading { stage = .entries }
    }
}

/// The Find Subtitles sheet.
struct SubtitleSearchView: View {
    @State var model: SubtitleSearchModel
    let onPick: (PickedSubtitle) -> Void
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(title)
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", action: onClose).accessibilityIdentifier("subtitles.cancel")
                    }
                    if canGoBack {
                        ToolbarItem(placement: .navigation) {
                            Button("Back", systemImage: "chevron.backward") { model.back() }
                        }
                    }
                }
                .overlay {
                    if model.isWorking { ProgressView().controlSize(.large) }
                }
        }
        .task { await model.start() }
    }

    private var title: String {
        switch model.stage {
        case .files(let entry), .archive(let entry, _): entry.name
        default: "Find Subtitles"
        }
    }

    private var canGoBack: Bool {
        switch model.stage {
        case .files, .archive: true
        default: false
        }
    }

    @ViewBuilder private var content: some View {
        switch model.stage {
        case .needsKey:
            ContentUnavailableView {
                Label("Add a Jimaku Key", systemImage: "key")
            } description: {
                Text("Subtitles come from Jimaku. Make a free account at jimaku.cc, create an API key on its Account page, and add it in Settings → Jimaku.")
            }
            .accessibilityIdentifier("subtitles.needsKey")
        case .loading:
            Color.clear
        case .entries:
            List {
                Section {
                    HStack {
                        TextField("Show name", text: $model.query)
                            .onSubmit { Task { await model.search() } }
                            .autocorrectionDisabled()
                        Button("Search") { Task { await model.search() } }
                    }
                }
                errorRow
                Section(model.entries.isEmpty ? "No matches" : "Shows") {
                    ForEach(model.entries) { entry in
                        Button { Task { await model.open(entry) } } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.name)
                                if let japanese = entry.japaneseName {
                                    Text(japanese).font(.subheadline).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .accessibilityIdentifier("subtitles.entry")
                    }
                }
            }
        case .files:
            List {
                errorRow
                Section {
                    ForEach(model.files) { file in
                        fileRow(file)
                    }
                } header: {
                    Text(model.showsAllFiles ? "All files" : model.episode.map { "Episode \($0)" } ?? "Files")
                } footer: {
                    if !model.showsAllFiles {
                        Button("Show All Files") { Task { await model.showAllFiles() } }
                            .font(.footnote)
                    }
                }
            }
        case .archive(_, let file):
            List {
                errorRow
                Section(file.name) {
                    ForEach(model.members) { member in
                        Button(member.name) {
                            if let picked = model.pick(member) { onPick(picked) }
                        }
                        .accessibilityIdentifier("subtitles.member")
                    }
                }
            }
        }
    }

    private func fileRow(_ file: JimakuFile) -> some View {
        let kind = JimakuFileKind(fileName: file.name)
        return Button {
            Task { if let picked = await model.pick(file) { onPick(picked) } }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name).lineLimit(3)
                HStack {
                    if let size = file.size { Text(Int64(size).formatted(.byteCount(style: .file))) }
                    if case .unsupported(let type) = kind { Text("Can't open \(type) files") }
                    if kind == .zip { Text("Zip") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .disabled({ if case .unsupported = kind { true } else { false } }())
        .accessibilityIdentifier("subtitles.file")
    }

    @ViewBuilder private var errorRow: some View {
        if let error = model.error {
            Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        }
    }
}
