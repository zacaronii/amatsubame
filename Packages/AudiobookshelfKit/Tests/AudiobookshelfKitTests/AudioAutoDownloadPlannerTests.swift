import AudiobookshelfKit
import Core
import Foundation
import Testing

@Suite struct AudioAutoDownloadPlannerTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// Episodes 1…count, one a day (1 the oldest).
    func episodes(_ count: Int) throws -> [AudiobookshelfEpisode] {
        try (1...count).map { number in
            try JSONDecoder().decode(AudiobookshelfEpisode.self, from: Data("""
                {"id":"e\(number)","libraryItemId":"show","title":"Episode \(number)","publishedAt":\(Double(number) * 86_400_000)}
                """.utf8))
        }
    }

    func progress(_ number: Int, at time: Double = 60, finished: Bool = false) -> AudiobookshelfProgress {
        AudiobookshelfProgress(libraryItemId: "show", episodeId: "e\(number)", duration: 600, progress: time / 600,
                               currentTime: time, isFinished: finished, lastUpdate: 0)
    }

    func ids(_ episodes: [AudiobookshelfEpisode]) -> [String] { episodes.map(\.id) }

    @Test func newestKeepsTheLatestLessFinished() throws {
        let progress = [progress(5, finished: true)].reduce(into: [:]) { $0[$1.key] = $1 }
        let kept = AudioAutoDownloadPlanner.episodesToKeep(try episodes(5), rule: .init(ahead: 3, order: .newest), progress: progress)
        // Finishing the newest doesn't pull in an older one.
        #expect(ids(kept) == ["e4", "e3"])
    }

    @Test func inOrderKeepsFromTheOneYoureOn() throws {
        var progress: [String: AudiobookshelfProgress] = [:]
        for item in [self.progress(1, finished: true), self.progress(2, finished: true), self.progress(3)] { progress[item.key] = item }
        let rule = AudioAutoDownloadPlanner.Rule(ahead: 2, order: .inOrder)
        #expect(ids(AudioAutoDownloadPlanner.episodesToKeep(try episodes(6), rule: rule, progress: progress)) == ["e3", "e4"])
        // Nothing started: from the first episode.
        #expect(ids(AudioAutoDownloadPlanner.episodesToKeep(try episodes(6), rule: rule, progress: [:])) == ["e1", "e2"])
        // Off keeps nothing.
        #expect(AudioAutoDownloadPlanner.episodesToKeep(try episodes(6), rule: .init(ahead: 0, order: .inOrder), progress: progress).isEmpty)
    }

    @Test func aLibrarysRuleCoversShowsPlayedLately() {
        let library = AudioAutoDownloadSetting(scope: AudioAutoDownloadSetting.library("lib"), ahead: 2, order: .inOrder)
        let rule = AudioAutoDownloadPlanner.Rule(ahead: 2, order: .inOrder)
        #expect(AudioAutoDownloadPlanner.coverage(library: library, show: nil, lastPlayed: now - 3600, now: now) == .on(rule))
        #expect(AudioAutoDownloadPlanner.coverage(library: library, show: nil, lastPlayed: now - 16 * 86_400, now: now) == .paused)
        #expect(AudioAutoDownloadPlanner.coverage(library: library, show: nil, lastPlayed: nil, now: now) == .paused)
        #expect(AudioAutoDownloadPlanner.coverage(library: nil, show: nil, lastPlayed: now, now: now) == .off)
    }

    @Test func aShowsOwnChoiceWins() {
        let library = AudioAutoDownloadSetting(scope: AudioAutoDownloadSetting.library("lib"), ahead: 2)
        let never = AudioAutoDownloadSetting(scope: AudioAutoDownloadSetting.show("show"), isOn: false)
        #expect(AudioAutoDownloadPlanner.coverage(library: library, show: never, lastPlayed: now, now: now) == .off)
        // On: even unplayed, with its own count, or its library's, or 3.
        let own = AudioAutoDownloadSetting(scope: AudioAutoDownloadSetting.show("show"), ahead: 5, order: .inOrder, isOn: true)
        #expect(AudioAutoDownloadPlanner.coverage(library: library, show: own, lastPlayed: nil, now: now) == .on(.init(ahead: 5, order: .inOrder)))
        let on = AudioAutoDownloadSetting(scope: AudioAutoDownloadSetting.show("show"), isOn: true)
        #expect(AudioAutoDownloadPlanner.coverage(library: library, show: on, lastPlayed: nil, now: now) == .on(.init(ahead: 2, order: .newest)))
        #expect(AudioAutoDownloadPlanner.coverage(library: nil, show: on, lastPlayed: nil, now: now) == .on(.init(ahead: 3, order: .newest)))
    }

    @Test func playedDownloadsGoADayAfterFinishing() {
        func finished(_ id: String, hoursAgo: Double) -> AudiobookshelfProgress {
            AudiobookshelfProgress(libraryItemId: "show", episodeId: id, duration: 600, progress: 1, currentTime: 600, isFinished: true,
                                   lastUpdate: (now.timeIntervalSince1970 - hoursAgo * 3600) * 1000)
        }
        var progress: [String: AudiobookshelfProgress] = [:]
        for item in [finished("old", hoursAgo: 30), finished("recent", hoursAgo: 2), finished("mine", hoursAgo: 48), finished("playing", hoursAgo: 48)] {
            progress[item.key] = item
        }
        progress["show/unplayed"] = self.progress(1)
        let downloads = ["old", "recent", "mine", "playing", "unplayed"].map {
            AudioAutoDownloadPlanner.Download(key: "show/\($0)", byHand: $0 == "mine")
        }
        #expect(AudioAutoDownloadPlanner.playedToRemove(downloads, progress: progress, keepsManual: true, playing: "show/playing", now: now)
                == ["show/old"])
        // Turned off, downloads made by hand go too.
        #expect(AudioAutoDownloadPlanner.playedToRemove(downloads, progress: progress, keepsManual: false, playing: "show/playing", now: now)
                == ["show/old", "show/mine"])
    }
}
