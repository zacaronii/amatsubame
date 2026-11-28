import Core
import Foundation

/// Decides what Kiku's download ahead keeps on the device for a show: which shows it covers
/// and which of their episodes. Progress is Audiobookshelf's, raised by this device's own.
public enum AudioAutoDownloadPlanner {
    /// A library's rule covers a show played within this long (Apple Podcasts pauses after 15 days).
    public static let playedWithin: TimeInterval = 15 * 24 * 3600

    public struct Rule: Equatable, Sendable {
        public var ahead: Int
        public var order: AudioAutoDownloadSetting.Order

        public init(ahead: Int, order: AudioAutoDownloadSetting.Order) {
            self.ahead = ahead
            self.order = order
        }
    }

    /// Why a show's episodes are (or aren't) downloaded ahead.
    public enum Coverage: Equatable, Sendable {
        case on(Rule)
        /// Its library downloads ahead, but the show hasn't been played lately.
        case paused
        case off
    }

    /// The show's own choice wins; otherwise its library's rule, while the show has been played
    /// within `playedWithin`. A show turned on without a count of its own takes its library's,
    /// or 3 when the library's is off.
    public static func coverage(library: AudioAutoDownloadSetting?, show: AudioAutoDownloadSetting?,
                                lastPlayed: Date?, now: Date) -> Coverage {
        let libraryRule = library.flatMap { $0.ahead > 0 ? Rule(ahead: $0.ahead, order: $0.order) : nil }
        switch show?.isOn {
        case false?:
            return .off
        case true?:
            guard let show, show.ahead > 0 else { return .on(libraryRule ?? Rule(ahead: 3, order: show?.order ?? .newest)) }
            return .on(Rule(ahead: show.ahead, order: show.order))
        case nil:
            guard let libraryRule else { return .off }
            guard let lastPlayed, now.timeIntervalSince(lastPlayed) <= playedWithin else { return .paused }
            return .on(libraryRule)
        }
    }

    /// The episodes to keep downloaded under `rule`.
    /// - Newest: the latest `ahead` episodes, less those finished.
    /// - In order: from the episode you're on (the latest one started, or the oldest when none
    ///   is), the next `ahead` unfinished ones, oldest first.
    public static func episodesToKeep(_ episodes: [AudiobookshelfEpisode], rule: Rule,
                                      progress: [String: AudiobookshelfProgress]) -> [AudiobookshelfEpisode] {
        guard rule.ahead > 0 else { return [] }
        func finished(_ episode: AudiobookshelfEpisode) -> Bool { progress[episode.key]?.isFinished == true }
        switch rule.order {
        case .newest:
            let newest = episodes.sorted { ($0.publishedAt ?? 0) > ($1.publishedAt ?? 0) }.prefix(rule.ahead)
            return newest.filter { !finished($0) }
        case .inOrder:
            let oldest = episodes.sorted { ($0.publishedAt ?? 0) < ($1.publishedAt ?? 0) }
            let started = oldest.lastIndex { progress[$0.key].map { $0.currentTime > 0 || $0.isFinished } ?? false } ?? 0
            return Array(oldest[started...].filter { !finished($0) }.prefix(rule.ahead))
        }
    }

    /// Remove Played Downloads waits this long after an episode or book is finished.
    public static let removeAfter: TimeInterval = 24 * 3600

    /// A download Remove Played Downloads may consider: its episode or book key, and whether you
    /// made it yourself.
    public struct Download: Equatable, Sendable {
        public var key: String
        public var byHand: Bool

        public init(key: String, byHand: Bool) {
            self.key = key
            self.byHand = byHand
        }
    }

    /// Downloads finished at least `removeAfter` ago, except the one playing and, with
    /// `keepsManual`, the ones you made yourself.
    public static func playedToRemove(_ downloads: [Download], progress: [String: AudiobookshelfProgress], keepsManual: Bool,
                                      playing: String?, now: Date) -> [String] {
        downloads.compactMap { download in
            guard download.key != playing, !(keepsManual && download.byHand),
                  let place = progress[download.key], place.isFinished,
                  now.timeIntervalSince(place.updatedAt) >= removeAfter else { return nil }
            return download.key
        }
    }
}
