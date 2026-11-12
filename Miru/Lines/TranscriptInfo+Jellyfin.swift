import Core
import Foundation
import JellyfinKit

extension TranscriptInfo {
    /// The saved-transcript record for a Jellyfin item, played now.
    static func make(item: JellyfinItem, mediaSourceId: String, streamIndex: Int, audioIndex: Int?, now: Date = Date()) -> TranscriptInfo {
        TranscriptInfo(
            itemId: item.id, seriesId: item.seriesId, seriesName: item.seriesName, title: item.name,
            season: item.parentIndexNumber, episode: item.indexNumber, mediaSourceId: mediaSourceId,
            streamIndex: streamIndex, audioIndex: audioIndex, runtime: item.duration,
            lastPlayedAt: item.userData?.lastPlayedDate ?? now, savedAt: now)
    }

    /// "S1E5" for episodes.
    var episodeLabel: String? {
        guard let episode else { return nil }
        return season.map { "S\($0)E\(episode)" } ?? "E\(episode)"
    }

    /// The show (or movie) name for cards and rows.
    var showName: String { seriesName ?? title }
}
