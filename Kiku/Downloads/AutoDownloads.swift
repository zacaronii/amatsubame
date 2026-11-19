import AudiobookshelfKit
import Core
import Foundation
import Observation

/// Download ahead (off unless turned on): per podcast library, the next episodes of each show
/// played in the last 15 days; a show can be always on or never. Only adds downloads, which
/// show "Ahead" in Storage. Runs after the library refreshes, when the player closes and when
/// the settings change, over Wi-Fi unless cellular downloads are on.
@MainActor @Observable
final class AudioAutoDownloadManager {
    /// By scope ("library:<id>", "show:<item id>").
    private(set) var settings: [String: AudioAutoDownloadSetting] = [:]

    @ObservationIgnored private let store: AudioAutoDownloadSettingsStore
    @ObservationIgnored private weak var environment: KikuEnvironment?
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var isRunning = false

    init(environment: KikuEnvironment) {
        self.environment = environment
        store = AudioAutoDownloadSettingsStore(database: environment.common.database)
        settings = (try? store.all()) ?? [:]
    }

    func library(_ libraryId: String) -> AudioAutoDownloadSetting {
        settings[AudioAutoDownloadSetting.library(libraryId)] ?? AudioAutoDownloadSetting(scope: AudioAutoDownloadSetting.library(libraryId))
    }

    func show(_ itemId: String) -> AudioAutoDownloadSetting {
        settings[AudioAutoDownloadSetting.show(itemId)] ?? AudioAutoDownloadSetting(scope: AudioAutoDownloadSetting.show(itemId))
    }

    func save(_ setting: AudioAutoDownloadSetting) {
        try? store.save(setting)
        settings = (try? store.all()) ?? [:]
        schedule(after: 1)
    }

    /// Whether and how a show is downloaded ahead now.
    func coverage(of show: AudiobookshelfItem) -> AudioAutoDownloadPlanner.Coverage {
        AudioAutoDownloadPlanner.coverage(library: settings[AudioAutoDownloadSetting.library(show.libraryId)],
                                          show: settings[AudioAutoDownloadSetting.show(show.id)],
                                          lastPlayed: lastPlayed()[show.id], now: .now)
    }

    /// Runs once things settle (e.g. after the player's progress has been saved).
    func schedule(after seconds: Double = 3) {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            await self?.run()
        }
    }

    func run() async {
        guard !isRunning, !settings.isEmpty, let environment, environment.common.reachability.isOnline,
              let client = environment.audiobookshelfClient() else { return }
        isRunning = true
        defer { isRunning = false }
        let library = environment.library
        let hidden = library.hiddenLibraries
        let podcastLibraries = Set(library.libraries.filter { $0.mediaType == .podcast && !hidden.contains($0.id) }.map(\.id))
        let played = lastPlayed()
        for show in library.shows where podcastLibraries.contains(show.libraryId) {
            let coverage = AudioAutoDownloadPlanner.coverage(
                library: settings[AudioAutoDownloadSetting.library(show.libraryId)],
                show: settings[AudioAutoDownloadSetting.show(show.id)], lastPlayed: played[show.id], now: .now)
            guard case .on(let rule) = coverage, let item = try? await client.item(id: show.id) else { continue }
            let keep = AudioAutoDownloadPlanner.episodesToKeep(item.media.episodes ?? [], rule: rule, progress: library.progress)
            for episode in keep where environment.downloader.records[episode.key] == nil {
                await environment.downloader.download(library.entry(episode, showTitle: show.title), reason: .ahead)
            }
        }
    }

    /// When each show was last played: here (Stats) or anywhere Audiobookshelf heard of.
    private func lastPlayed() -> [String: Date] {
        guard let environment else { return [:] }
        let since = Date.now.addingTimeInterval(-AudioAutoDownloadPlanner.playedWithin)
        var result: [String: Date] = [:]
        for session in (try? environment.common.activity.sessions(kind: .listening, since: since)) ?? [] {
            result[session.seriesKey] = max(result[session.seriesKey] ?? .distantPast, session.end)
        }
        for progress in environment.library.progress.values where progress.episodeId?.isEmpty == false {
            result[progress.libraryItemId] = max(result[progress.libraryItemId] ?? .distantPast, progress.updatedAt)
        }
        return result
    }
}
