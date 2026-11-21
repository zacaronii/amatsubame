import AudiobookshelfKit
import Core
import Foundation
@testable import Kiku
import KikuWatchLink
import Testing

/// The automatic rules for Apple Watch (docs/KIKU_PLAN.md milestone 4).
@MainActor @Suite struct WatchRulesPlannerTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func item(_ show: String, _ episode: String, size: Int64 = 50_000_000, reason: WatchItem.Reason? = nil) -> WatchItem {
        WatchItem(itemId: show, episodeId: episode, ino: "1", fileExtension: "mp3", title: episode, subtitle: show,
                  duration: 1800, size: size, addedAt: now, reason: reason)
    }

    func candidates(_ show: String, _ episodes: [String], size: Int64 = 50_000_000) -> (showId: String, episodes: [WatchRulesPlanner.Candidate]) {
        (show, episodes.map { WatchRulesPlanner.Candidate(key: "\(show)/\($0)", size: size) })
    }

    func progress(_ key: String, at time: Double, finished: Bool = false, daysAgo: Double = 0) -> (String, AudiobookshelfProgress) {
        let parts = key.split(separator: "/").map(String.init)
        return (key, AudiobookshelfProgress(libraryItemId: parts[0], episodeId: parts[1], duration: 1800, progress: time / 1800,
                                            currentTime: time, isFinished: finished,
                                            lastUpdate: now.addingTimeInterval(-daysAgo * 86_400).timeIntervalSince1970 * 1000))
    }

    @Test func downloadAheadTakesTheFirstFewOfEachShow() {
        let ahead = WatchRulesPlanner.Ahead(shows: [candidates("a", ["1", "2", "3", "4"]), candidates("b", ["1", "2"])], judged: ["a", "b"])
        let plan = WatchRulesPlanner.plan(items: [item("a", "1", reason: .ahead)], ahead: ahead, rules: KikuWatchRules(ahead: 2),
                                          declined: ["b/2"], progress: [:], playing: nil, now: now)
        // a/1 is there already; b/2 was removed from the watch, so it stays off.
        #expect(plan.add == ["a/2", "b/1"])
        #expect(plan.remove.isEmpty && plan.overLimit.isEmpty)
    }

    @Test func oneThatDropsOutGoesUnlessItsStarted() {
        let items = [item("a", "old", reason: .ahead), item("a", "started", reason: .ahead), item("a", "mine"),
                     item("c", "unjudged", reason: .ahead)]
        let ahead = WatchRulesPlanner.Ahead(shows: [candidates("a", ["new"])], judged: ["a"])
        let plan = WatchRulesPlanner.plan(items: items, ahead: ahead, rules: KikuWatchRules(ahead: 1), declined: [],
                                          progress: Dictionary(uniqueKeysWithValues: [progress("a/started", at: 300)]),
                                          playing: nil, now: now)
        // Sent by hand, half-listened, or from a show whose list isn't known: they stay.
        #expect(plan.remove == ["a/old"])
        #expect(plan.add == ["a/new"])
        // Download ahead turned off: its items go (the started one still stays).
        let off = WatchRulesPlanner.plan(items: items, ahead: ahead, rules: KikuWatchRules(), declined: [],
                                         progress: Dictionary(uniqueKeysWithValues: [progress("a/started", at: 300)]), playing: nil, now: now)
        #expect(off.remove == ["a/old"] && off.add.isEmpty)
        // Offline: nothing moves.
        #expect(WatchRulesPlanner.plan(items: items, ahead: nil, rules: KikuWatchRules(ahead: 1), declined: [],
                                       progress: [:], playing: nil, now: now) == WatchRulesPlanner.Plan())
    }

    @Test func removePlayedWaitsADayAndKeepsWhatYouSent() {
        let items = [item("a", "1", reason: .ahead), item("a", "2"), item("a", "3", reason: .started), item("a", "4", reason: .started)]
        let progress = Dictionary(uniqueKeysWithValues: [progress("a/1", at: 1800, finished: true, daysAgo: 2),
                                                          progress("a/2", at: 1800, finished: true, daysAgo: 2),
                                                          progress("a/3", at: 1800, finished: true, daysAgo: 0.5),
                                                          progress("a/4", at: 1800, finished: true, daysAgo: 3)])
        let plan = WatchRulesPlanner.plan(items: items, ahead: nil, rules: KikuWatchRules(removesPlayed: true), declined: [],
                                          progress: progress, playing: "a/4", now: now)
        // a/2 was sent by hand; a/3 finished only hours ago; a/4 is playing on the phone.
        #expect(plan.remove == ["a/1"])
        let all = WatchRulesPlanner.plan(items: items, ahead: nil, rules: KikuWatchRules(removesPlayed: true, keepsManual: false),
                                         declined: [], progress: progress, playing: nil, now: now)
        #expect(all.remove == ["a/1", "a/2", "a/4"])
    }

    @Test func theStorageLimitStopsDownloadAhead() {
        let items = [item("a", "mine", size: 900_000_000)]
        let ahead = WatchRulesPlanner.Ahead(shows: [candidates("a", ["1", "2", "3"], size: 400_000_000), candidates("b", ["1"], size: 10_000_000)],
                                            judged: ["a", "b"])
        let plan = WatchRulesPlanner.plan(items: items, ahead: ahead, rules: KikuWatchRules(ahead: 3, storageLimit: 2_000_000_000),
                                          declined: [], progress: [:], playing: nil, now: now)
        // 0.9 + 0.4 + 0.4 = 1.7 GB; the next 0.4 doesn't fit, and nothing after it is added either.
        #expect(plan.add == ["a/1", "a/2"])
        #expect(plan.overLimit == ["a/3", "b/1"])
        #expect(WatchRulesPlanner.fits(100_000_000, items: items, limit: 1_000_000_000))
        #expect(!WatchRulesPlanner.fits(200_000_000, items: items, limit: 1_000_000_000))
        #expect(WatchRulesPlanner.fits(5_000_000_000, items: items, limit: 0))
    }
}
