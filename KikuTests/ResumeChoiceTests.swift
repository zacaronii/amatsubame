import AudiobookshelfKit
import Core
import Foundation
@testable import Kiku
import Testing

/// Never back a long way silently (docs/KIKU_PLAN.md milestone 3): the player asks when the
/// newer place (the watch's, say) is more than a minute behind this phone's.
@MainActor @Suite struct ResumeChoiceTests {
    let phoneAt = Date(timeIntervalSince1970: 1_800_000_000)

    func entry(server position: Double, at date: Date, finished: Bool = false) -> EpisodeEntry {
        let json = #"{"id":"ep","libraryItemId":"show","title":"Episode","duration":1800,"audioFile":{"ino":"1","duration":1800}}"#
        let episode = try! JSONDecoder().decode(AudiobookshelfEpisode.self, from: Data(json.utf8))
        let progress = AudiobookshelfProgress(libraryItemId: "show", episodeId: "ep", duration: 1800, progress: position / 1800,
                                              currentTime: position, isFinished: finished, lastUpdate: date.timeIntervalSince1970 * 1000)
        return EpisodeEntry(episode: episode, showTitle: "Show", progress: progress)
    }

    func local(_ position: Double) -> LocalWatchProgress {
        LocalWatchProgress(itemId: "show/ep", seriesId: "show", position: position, duration: 1800, updatedAt: phoneAt)
    }

    func choice(local: LocalWatchProgress?, entry: EpisodeEntry, watch: Date? = nil) -> PlaybackModel.ResumeChoice? {
        let position = LocalWatchProgress.resumePosition(local: local, server: entry.progress?.currentTime, serverDate: entry.progress?.updatedAt)
        return PlaybackModel.resumeChoice(local: local, entry: entry, position: position, autoplay: true, watchPlayedAt: watch)
    }

    @Test func aNewerPlaceFarBehindAsks() throws {
        let later = phoneAt.addingTimeInterval(600)
        let asked = try #require(choice(local: local(1082), entry: entry(server: 760, at: later), watch: later))
        #expect(asked.newer == 760 && asked.mine == 1082 && asked.newerFrom == "Apple Watch" && asked.plays)
        // Not the watch's: another app or device.
        #expect(choice(local: local(1082), entry: entry(server: 760, at: later))?.newerFrom == "Audiobookshelf")
    }

    @Test func otherwiseItJustResumes() {
        let later = phoneAt.addingTimeInterval(600)
        // Ahead, or less than a minute back: no question.
        #expect(choice(local: local(700), entry: entry(server: 760, at: later)) == nil)
        #expect(choice(local: local(800), entry: entry(server: 760, at: later)) == nil)
        // This phone's place is the newer one.
        #expect(choice(local: local(1082), entry: entry(server: 760, at: phoneAt.addingTimeInterval(-600))) == nil)
        // Finished elsewhere, or this phone was at the very end.
        #expect(choice(local: local(1082), entry: entry(server: 760, at: later, finished: true)) == nil)
        #expect(choice(local: local(1790), entry: entry(server: 760, at: later)) == nil)
        #expect(choice(local: nil, entry: entry(server: 760, at: later)) == nil)
    }
}
