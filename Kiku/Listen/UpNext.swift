import AudiobookshelfKit
import Core
import Foundation

/// Up Next: episodes to play after this one, any show, per podcast library. Kept on
/// Audiobookshelf as the library's "Up Next" playlist (the outbox sends each change as the
/// whole list), so it's the same on every device and in Audiobookshelf's own apps. An episode
/// leaves it when it starts; when one ends, the first in Up Next plays before the show's next.
extension KikuEnvironment {
    var upNextStore: UpNextStore { UpNextStore(database: common.database) }

    /// The podcast library an episode belongs to (books aren't queued).
    func libraryId(of entry: EpisodeEntry) -> String? {
        guard !entry.isBook else { return nil }
        return library.shows.first { $0.id == entry.itemId }?.libraryId
    }

    func isInUpNext(_ entry: EpisodeEntry) -> Bool {
        upNext.values.contains { $0.contains { $0.key == entry.id } }
    }

    func addToUpNext(_ entry: EpisodeEntry, next: Bool) {
        guard let libraryId = libraryId(of: entry) else { return }
        let item = UpNextItem(itemId: entry.itemId, episodeId: entry.episode.id, title: entry.episode.title, showTitle: entry.showTitle)
        let list = next ? try? upNextStore.playNext(item, libraryId: libraryId) : try? upNextStore.playLast(item, libraryId: libraryId)
        if let list { changedUpNext(list, libraryId: libraryId) }
    }

    func removeFromUpNext(_ item: UpNextItem, libraryId: String) {
        if let list = try? upNextStore.remove(key: item.key, libraryId: libraryId) { changedUpNext(list, libraryId: libraryId) }
    }

    func moveUpNext(from source: IndexSet, to destination: Int, libraryId: String) {
        if let list = try? upNextStore.move(from: source, to: destination, libraryId: libraryId) { changedUpNext(list, libraryId: libraryId) }
    }

    func clearUpNext(libraryId: String) {
        try? upNextStore.set([], libraryId: libraryId)
        changedUpNext([], libraryId: libraryId)
    }

    /// An episode started: out of Up Next.
    func leaveUpNext(_ entry: EpisodeEntry) {
        for (libraryId, items) in upNext where items.contains(where: { $0.key == entry.id }) {
            if let list = try? upNextStore.remove(key: entry.id, libraryId: libraryId) { changedUpNext(list, libraryId: libraryId) }
        }
    }

    /// An episode ended: the first in its library's Up Next (else any library's) starts.
    /// False when Up Next is empty.
    func playUpNext(after entry: EpisodeEntry) -> Bool {
        let preferred = libraryId(of: entry)
        guard let (libraryId, first) = (preferred.flatMap { id in upNext[id]?.first.map { (id, $0) } }
            ?? upNext.lazy.compactMap { id, items in items.first.map { (id, $0) } }.first) else { return false }
        Task {
            if library.showEpisodes[first.itemId] == nil { await library.loadShow(first.itemId) }
            guard playback?.key == entry.id else { return }
            guard let episode = library.showEpisodes[first.itemId]?.first(where: { $0.id == first.episodeId })
                ?? downloadedEntries.first(where: { $0.id == first.key })?.episode else {
                // Gone from the server: out of the queue, and on to the next.
                removeFromUpNext(first, libraryId: libraryId)
                _ = playUpNext(after: entry)
                return
            }
            let shows = showsPlayer
            play(library.entry(episode, showTitle: first.showTitle))
            showsPlayer = shows
        }
        return true
    }

    /// Every library's Up Next as one list (most have one podcast library).
    var upNextFlat: [(item: UpNextItem, libraryId: String)] {
        upNext.keys.sorted().flatMap { id in (upNext[id] ?? []).map { (item: $0, libraryId: id) } }
    }

    /// Plays an episode from Up Next (it leaves the queue as it starts).
    func playUpNextItem(_ item: UpNextItem, libraryId: String) {
        Task {
            if library.showEpisodes[item.itemId] == nil { await library.loadShow(item.itemId) }
            guard let episode = library.showEpisodes[item.itemId]?.first(where: { $0.id == item.episodeId })
                ?? downloadedEntries.first(where: { $0.id == item.key })?.episode else {
                removeFromUpNext(item, libraryId: libraryId)
                return
            }
            play(library.entry(episode, showTitle: item.showTitle))
        }
    }

    func reloadUpNext() {
        upNext = ((try? upNextStore.all()) ?? [:]).filter { !$0.value.isEmpty }
    }

    /// Takes Audiobookshelf's Up Next for each podcast library, unless a change made here is
    /// still waiting to be sent (that one wins, and goes out next).
    func refreshUpNext() async {
        reloadUpNext()
        guard let client = audiobookshelfClient() else { return }
        let waiting = Set(((try? common.outbox.jobs(states: [.pending, .inFlight, .failed])) ?? [])
            .filter { $0.kind == .audiobookshelfUpNext }.compactMap(\.coalesceKey))
        for podcasts in library.libraries where podcasts.mediaType == .podcast {
            let id = podcasts.id
            guard !waiting.contains(AudiobookshelfUpNextPayload(libraryId: id, items: []).coalesceKey) else { continue }
            var playlist: AudiobookshelfPlaylist?
            if let known = try? upNextStore.playlistId(libraryId: id) {
                playlist = try? await client.playlist(id: known)
            }
            if playlist == nil {
                guard let all = try? await client.playlists(libraryId: id) else { continue }
                playlist = all.first { $0.name == AudiobookshelfUpNextHandler.playlistName }
            }
            try? upNextStore.setPlaylistId(playlist?.id, libraryId: id)
            let items = (playlist?.items ?? []).compactMap { item -> UpNextItem? in
                guard let episodeId = item.episodeId else { return nil }
                let known = upNext[id]?.first { $0.itemId == item.libraryItemId && $0.episodeId == episodeId }
                return UpNextItem(itemId: item.libraryItemId, episodeId: episodeId,
                                  title: item.title ?? known?.title ?? "", showTitle: item.showTitle ?? known?.showTitle ?? "")
            }
            try? upNextStore.set(items, libraryId: id)
        }
        reloadUpNext()
    }

    private func changedUpNext(_ list: [UpNextItem], libraryId: String) {
        reloadUpNext()
        let payload = AudiobookshelfUpNextPayload(libraryId: libraryId, items: list)
        try? common.outbox.enqueue(payload, kind: .audiobookshelfUpNext, coalesceKey: payload.coalesceKey)
        common.syncNow(retryWaiting: false)
    }
}
