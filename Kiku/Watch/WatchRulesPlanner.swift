import AudiobookshelfKit
import Core
import Foundation
import KikuWatchLink

/// The automatic rules for Apple Watch (docs/KIKU_PLAN.md milestone 4), as a pure function:
/// what to add to the watch's list and what to take off, from the phone's download ahead lists.
enum WatchRulesPlanner {
    /// An episode a rule may add: its key and size.
    struct Candidate: Equatable {
        var key: String
        var size: Int64?
    }

    /// Each covered show's download ahead list, in order, the most recently played show first;
    /// `judged` is the shows whose lists are known (a show whose episodes couldn't be fetched
    /// isn't in it, so its items stay as they are).
    struct Ahead: Equatable {
        var shows: [(showId: String, episodes: [Candidate])]
        var judged: Set<String>

        static func == (lhs: Ahead, rhs: Ahead) -> Bool {
            lhs.judged == rhs.judged && lhs.shows.map(\.showId) == rhs.shows.map(\.showId)
                && lhs.shows.map(\.episodes) == rhs.shows.map(\.episodes)
        }
    }

    struct Plan: Equatable {
        /// Keys to add, in order.
        var add: [String] = []
        var remove: [String] = []
        /// What download ahead wanted but the storage limit stopped.
        var overLimit: [String] = []
    }

    /// - Remove Played: a day after an item is finished (not while the phone plays it); with
    ///   Keep Items You Sent by Hand, those stay.
    /// - Download ahead: the first `rules.ahead` of each show's list; one that drops out of it
    ///   goes, unless it's started and not finished. Nil `ahead` (offline): neither.
    /// - The storage limit counts everything on the list; download ahead stops at the first
    ///   episode that doesn't fit.
    static func plan(items: [WatchItem], ahead: Ahead?, rules: KikuWatchRules, declined: Set<String>,
                     progress: [String: AudiobookshelfProgress], playing: String?, now: Date) -> Plan {
        var plan = Plan()
        if rules.removesPlayed {
            plan.remove = AudioAutoDownloadPlanner.playedToRemove(
                items.map { AudioAutoDownloadPlanner.Download(key: $0.key, byHand: $0.reason == nil) },
                progress: progress, keepsManual: rules.keepsManual, playing: playing, now: now)
        }
        guard let ahead else { return plan }
        let wanted = rules.ahead > 0
            ? ahead.shows.flatMap { $0.episodes.prefix(rules.ahead) }.filter { !declined.contains($0.key) } : []
        let wantedKeys = Set(wanted.map(\.key))
        for item in items where item.reason == .ahead && ahead.judged.contains(item.itemId)
            && !wantedKeys.contains(item.key) && item.key != playing && !plan.remove.contains(item.key) {
            if let place = progress[item.key], place.currentTime > 0, !place.isFinished { continue }
            plan.remove.append(item.key)
        }
        let staying = items.filter { !plan.remove.contains($0.key) }
        let present = Set(staying.map(\.key))
        var total = staying.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
        for candidate in wanted where !present.contains(candidate.key) {
            if !plan.overLimit.isEmpty || (rules.storageLimit > 0 && total + (candidate.size ?? 0) > rules.storageLimit) {
                plan.overLimit.append(candidate.key)
                continue
            }
            plan.add.append(candidate.key)
            total += candidate.size ?? 0
        }
        return plan
    }

    /// Whether one more item fits under the limit (Once Started checks it before adding).
    static func fits(_ size: Int64?, items: [WatchItem], limit: Int64) -> Bool {
        limit <= 0 || items.reduce(Int64(0)) { $0 + ($1.size ?? 0) } + (size ?? 0) <= limit
    }
}
