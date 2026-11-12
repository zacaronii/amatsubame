import AppCommon
import Core
import KavitaKit
import Observation
import SwiftUI

/// Automatic downloads (opt-in per Kavita library): once a series is started, the volume being
/// read and the next few are downloaded; finished volumes can be removed. Runs at launch, on
/// returning to the app, when the reader closes or moves on, and when the settings change.
@MainActor @Observable
final class AutoDownloadManager {
    private(set) var settings: [Int: AutoDownloadSetting] = [:]
    /// The chapter on screen, never removed.
    @ObservationIgnored var openChapterId: Int?

    @ObservationIgnored private let store: AutoDownloadSettingsStore
    @ObservationIgnored private let library: KavitaLibraryRepository
    @ObservationIgnored private let progress: ReadingProgressStore
    @ObservationIgnored private let downloader: VolumeDownloader
    @ObservationIgnored private let reachability: Reachability
    @ObservationIgnored private let makeClient: () -> KavitaClient?
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var isRunning = false

    init(store: AutoDownloadSettingsStore, library: KavitaLibraryRepository, progress: ReadingProgressStore,
         downloader: VolumeDownloader, reachability: Reachability, makeClient: @escaping () -> KavitaClient?) {
        self.store = store
        self.library = library
        self.progress = progress
        self.downloader = downloader
        self.reachability = reachability
        self.makeClient = makeClient
        settings = (try? store.all()) ?? [:]
    }

    func setting(libraryId: Int) -> AutoDownloadSetting {
        settings[libraryId] ?? AutoDownloadSetting(libraryId: libraryId)
    }

    func save(_ setting: AutoDownloadSetting) {
        try? store.save(setting)
        settings = (try? store.all()) ?? [:]
        schedule(after: 1)
    }

    /// Runs once things settle (e.g. after the reader's progress has gone to Kavita).
    func schedule(after seconds: Double = 3) {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            await self?.run()
        }
    }

    func run() async {
        guard !isRunning, !settings.isEmpty, reachability.isOnline, let client = makeClient() else { return }
        isRunning = true
        defer { isRunning = false }
        for series in await seriesToCheck(client) {
            guard let rule = settings[series.libraryId] else { continue }
            let volumes = (try? await library.refreshVolumes(seriesId: series.id, using: client))
                ?? (try? library.cachedVolumes(seriesId: series.id)) ?? []
            let contents = KavitaSeriesContents(volumes: volumes)
            let local = Dictionary(((try? progress.progress(seriesId: series.id)) ?? []).map { ($0.chapterId, $0.page + 1) },
                                   uniquingKeysWith: max)
            for chapter in AutoDownloadPlanner.chaptersToKeep(contents, ahead: rule.ahead, local: local)
            where downloader.records[chapter.id] == nil {
                downloader.download(chapter, series: series, title: chapter.displayTitle(in: contents.volume(containing: chapter)),
                                    automatic: true)
            }
            guard rule.removesFinished else { continue }
            let downloaded = downloader.records.values
                .filter { $0.state == .done && VolumeDownloader.extra($0)?.seriesId == series.id }
                .compactMap { Int($0.itemKey) }
            for chapterId in AutoDownloadPlanner.finishedDownloads(downloaded, in: contents, local: local, openChapterId: openChapterId) {
                if let record = downloader.records[chapterId] { await downloader.delete(record) }
            }
        }
    }

    /// Started series in libraries downloading ahead (Kavita's On Deck, plus series read on
    /// this device), and series with downloads in libraries removing finished volumes.
    private func seriesToCheck(_ client: KavitaClient) async -> [KavitaSeries] {
        let aheadLibraries = Set(settings.values.filter { $0.ahead > 0 }.map(\.libraryId))
        let removingLibraries = Set(settings.values.filter(\.removesFinished).map(\.libraryId))
        var result: [Int: KavitaSeries] = [:]
        if !aheadLibraries.isEmpty {
            let onDeck = (try? await client.onDeck(pageSize: 50)) ?? []
            try? library.remember(onDeck)
            for (series, _) in onDeck where aheadLibraries.contains(series.libraryId) { result[series.id] = series }
            for recent in (try? progress.recentlyRead()) ?? [] where aheadLibraries.contains(recent.libraryId) && result[recent.seriesId] == nil {
                result[recent.seriesId] = try? library.cachedSeries(id: recent.seriesId)
            }
        }
        if !removingLibraries.isEmpty {
            for record in downloader.records.values where record.state == .done {
                guard let seriesId = VolumeDownloader.extra(record)?.seriesId, result[seriesId] == nil,
                      let series = try? library.cachedSeries(id: seriesId), removingLibraries.contains(series.libraryId) else { continue }
                result[seriesId] = series
            }
        }
        return Array(result.values)
    }
}

/// Settings → Downloads → Automatic Downloads: one row per library shown in the Library tab.
struct AutoDownloadSettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var libraries: [KavitaLibrary] = []

    var body: some View {
        List {
            Section {
                ForEach(libraries) { library in
                    NavigationLink {
                        AutoDownloadLibraryView(library: library)
                    } label: {
                        LabeledContent {
                            Text(summary(environment.autoDownloads.setting(libraryId: library.id)))
                        } label: {
                            Label(library.name, systemImage: library.isBookLibrary ? "book.closed" : "books.vertical")
                        }
                    }
                    .accessibilityIdentifier("autoDownloads.library")
                }
            } footer: {
                Text("Once you start a series, the volume you're reading and the next ones download automatically, over Wi-Fi unless Download over Cellular is on (Settings ▸ Downloads). Off for every library unless you turn it on.")
            }
        }
        .navigationTitle("Automatic Downloads")
        .onAppear {
            let hidden = environment.hiddenLibraries
            libraries = ((try? environment.kavitaLibrary.cachedLibraries()) ?? [])
                .filter { LibraryModel.readable($0) && !hidden.contains($0.id) }
        }
    }

    private func summary(_ setting: AutoDownloadSetting) -> String {
        var parts: [String] = []
        if setting.ahead > 0 { parts.append("\(setting.ahead) ahead") }
        if setting.removesFinished { parts.append("removes read") }
        return parts.isEmpty ? "Off" : parts.joined(separator: ", ")
    }
}

struct AutoDownloadLibraryView: View {
    @Environment(AppEnvironment.self) private var environment
    let library: KavitaLibrary

    static let choices = [0, 1, 2, 3, 5, 10]

    var body: some View {
        let setting = environment.autoDownloads.setting(libraryId: library.id)
        Form {
            Section {
                Picker("Download Ahead", selection: Binding(get: { setting.ahead }, set: { value in
                    var changed = setting
                    changed.ahead = value
                    environment.autoDownloads.save(changed)
                })) {
                    ForEach(Self.choices, id: \.self) { count in
                        Text(count == 0 ? "Off" : count == 1 ? "1 volume" : "\(count) volumes").tag(count)
                    }
                }
                .accessibilityIdentifier("autoDownloads.ahead")
            } footer: {
                Text("After you start a series in \(library.name), keeps the volume you're reading and this many after it downloaded.")
            }
            Section {
                Toggle("Remove Finished Volumes", isOn: Binding(get: { setting.removesFinished }, set: { value in
                    var changed = setting
                    changed.removesFinished = value
                    environment.autoDownloads.save(changed)
                }))
                .accessibilityIdentifier("autoDownloads.removeFinished")
            } footer: {
                Text("Downloaded volumes in \(library.name) are removed from this device once you've read them to the end, including ones you downloaded yourself.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle(library.name)
    }
}
