import AudiobookshelfKit
import Core
import Foundation
import Observation

/// An episode with what the screens show beside it: its show and the listener's place in it.
/// A book is one long "episode" with an empty id (`AudiobookshelfEpisode.wholeBook`), its
/// author as the show, and the book itself for chapters and files.
struct EpisodeEntry: Identifiable, Hashable, Codable {
    var episode: AudiobookshelfEpisode
    var showTitle: String
    var progress: AudiobookshelfProgress?
    var book: AudiobookshelfItem?

    var isBook: Bool { book != nil }
    /// What it belongs to, for Stats and Storage: the show, or the book itself.
    var collectionTitle: String { isBook ? episode.title : showTitle }
    var chapters: [AudiobookshelfChapter] { book?.media.chapters ?? [] }
    /// Kiku plays single-file books for now.
    var fileCount: Int { book?.media.tracks?.count ?? 1 }

    /// The chapter playing at `time` (books).
    func chapter(at time: Double) -> AudiobookshelfChapter? {
        chapters.last { $0.start <= time + 0.05 }
    }

    var id: String { episode.key }
    var itemId: String { episode.libraryItemId }
    var duration: Double { episode.length ?? progress?.duration ?? 0 }
    var isFinished: Bool { progress?.isFinished == true }
    var isStarted: Bool { (progress?.currentTime ?? 0) > 0 || isFinished }
    var timeLeft: Double { max(duration - (progress?.currentTime ?? 0), 0) }
    var fraction: Double { duration > 0 ? min((progress?.currentTime ?? 0) / duration, 1) : 0 }
}

/// Kiku's view of Audiobookshelf's libraries: shows and books, the newest episodes, what's in
/// progress, the listener's progress, and Kaku's transcript states. Shared by the tabs.
/// Each answer is kept in the database, so offline the library shows what it last saw.
@MainActor @Observable
final class PodcastLibrary {
    private(set) var shows: [AudiobookshelfItem] = []
    /// Books in the shown book libraries (as listed: no chapters or tracks).
    private(set) var books: [AudiobookshelfItem] = []
    /// Each book with its chapters and tracks, once its page or the player needed it.
    private(set) var bookDetails: [String: AudiobookshelfItem] = [:]
    /// Every library on the server (Settings ▸ Libraries shown in Kiku).
    private(set) var libraries: [AudiobookshelfLibrary] = []
    private(set) var newEpisodes: [EpisodeEntry] = []
    private(set) var continueListening: [EpisodeEntry] = []
    /// By episode key ("<item>/<episode>", a book's item id), from Audiobookshelf, then updated as you listen.
    private(set) var progress: [String: AudiobookshelfProgress] = [:]
    /// Kaku's answer per episode key; empty when Kaku isn't set up.
    private(set) var transcriptStatus: [String: KakuStatus] = [:]
    /// Each show's episodes, once its page has opened.
    private(set) var showEpisodes: [String: [AudiobookshelfEpisode]] = [:]
    private(set) var isLoading = false
    private(set) var error: String?
    /// Audiobookshelf couldn't be reached: the shelves are the saved copy, and only downloads play.
    private(set) var isOffline = false
    /// Shows with unplayed episodes since the newest one started, from the newest episodes list.
    private(set) var newCounts: [String: Int] = [:]
    @ObservationIgnored private weak var environment: KikuEnvironment?
    @ObservationIgnored private let cache: AudiobookshelfCacheStore
    @ObservationIgnored private var restored = false

    /// What the home shelves were built from, saved after each refresh.
    struct Saved: Codable {
        var server: URL
        var shows: [AudiobookshelfItem]
        var newEpisodes: [EpisodeEntry]
        var continueListening: [EpisodeEntry]
        var progress: [String: AudiobookshelfProgress]
        var transcriptStatus: [String: KakuStatus]
        var newCounts: [String: Int]
        var books: [AudiobookshelfItem]?
        var libraries: [AudiobookshelfLibrary]?
    }

    init(environment: KikuEnvironment) {
        self.environment = environment
        cache = AudiobookshelfCacheStore(database: environment.common.database)
    }

    private var server: URL? { environment?.audiobookshelfClient()?.baseURL }

    func showTitle(_ itemId: String) -> String {
        shows.first { $0.id == itemId }?.title
            ?? environment?.downloadedEntries.first { $0.itemId == itemId }?.showTitle ?? ""
    }

    func entry(_ episode: AudiobookshelfEpisode, showTitle: String? = nil) -> EpisodeEntry {
        EpisodeEntry(episode: episode, showTitle: showTitle ?? episode.podcast?.metadata.title ?? self.showTitle(episode.libraryItemId),
                     progress: progress[episode.key])
    }

    /// A book to play (needs its details: chapters and tracks).
    func entry(book: AudiobookshelfItem) -> EpisodeEntry? {
        guard let episode = AudiobookshelfEpisode.wholeBook(book) else { return nil }
        return EpisodeEntry(episode: episode, showTitle: book.media.metadata.authorName ?? "", progress: progress[book.id], book: book)
    }

    func book(_ itemId: String) -> AudiobookshelfItem? {
        bookDetails[itemId] ?? books.first { $0.id == itemId }
    }

    /// Libraries hidden in Settings stay off every shelf.
    var hiddenLibraries: Set<String> {
        guard let environment else { return [] }
        return Set(ListenSettings.load(environment.common.database).hiddenLibraries)
    }

    func setHidden(_ libraryId: String, _ hidden: Bool) async {
        guard let environment else { return }
        var settings = ListenSettings.load(environment.common.database)
        settings.hiddenLibraries.removeAll { $0 == libraryId }
        if hidden { settings.hiddenLibraries.append(libraryId) }
        try? settings.save(environment.common.database)
        await refresh()
    }

    /// Just the server's libraries, for Settings ▸ Libraries before the Listen tab has loaded.
    func refreshLibraries() async {
        guard let client = environment?.audiobookshelfClient() else { return }
        restoreSaved()
        if let all = try? await client.libraries() { libraries = all }
    }

    func refresh() async {
        guard let environment, let client = environment.audiobookshelfClient() else { return }
        restoreSaved()
        isLoading = true
        defer { isLoading = false }
        do {
            let all = try await client.libraries()
            libraries = all
            let hidden = hiddenLibraries
            let shown = all.filter { !hidden.contains($0.id) }
            async let me = client.me()
            async let inProgress = client.itemsInProgress(limit: 20)
            var shows: [AudiobookshelfItem] = []
            var books: [AudiobookshelfItem] = []
            var recent: [AudiobookshelfEpisode] = []
            for library in shown {
                switch library.mediaType {
                case .podcast:
                    shows += try await client.items(libraryId: library.id)
                    recent += try await client.recentEpisodes(libraryId: library.id, limit: 100)
                case .book:
                    books += try await client.items(libraryId: library.id)
                }
            }
            let user = try await me
            progress = Dictionary(user.mediaProgress.map { ($0.key, $0) }, uniquingKeysWith: { $1 })
            self.shows = shows.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            self.books = books.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            recent.sort { ($0.publishedAt ?? 0) > ($1.publishedAt ?? 0) }
            newEpisodes = recent.map { entry($0) }.filter { !$0.isFinished }.prefix(20).map(\.self)
            var listening: [EpisodeEntry] = []
            for item in try await inProgress where !hidden.contains(item.libraryId) {
                if let episode = item.recentEpisode {
                    listening.append(entry(episode, showTitle: item.title))
                } else if item.isBook, let details = await details(item.id), let book = entry(book: details) {
                    listening.append(book)
                }
            }
            continueListening = listening.filter { !$0.isFinished && $0.progress?.hideFromContinueListening != true }
            newCounts = Dictionary(grouping: recent, by: \.libraryItemId).mapValues { episodes in
                EpisodeNews.newCount(episodes: episodes.map { (published: $0.publishedDate, started: progress[$0.key].map { $0.currentTime > 0 || $0.isFinished } ?? false) })
            }
            error = nil
            isOffline = false
            await loadStatuses(newEpisodes.map(\.episode) + continueListening.map(\.episode))
            save()
        } catch let failure {
            if !failure.isCancellation { error = failure.localizedDescription }
            isOffline = Self.isOffline(failure)
        }
    }

    /// The saved shelves, shown at once and kept when the server can't be reached.
    private func restoreSaved() {
        guard !restored, let server else { return }
        restored = true
        guard let data = try? cache.data(for: "home"), let saved = try? JSONDecoder().decode(Saved.self, from: data),
              saved.server == server else { return }
        shows = saved.shows
        newEpisodes = saved.newEpisodes
        continueListening = saved.continueListening
        progress.merge(saved.progress) { current, _ in current }
        transcriptStatus.merge(saved.transcriptStatus) { current, _ in current }
        newCounts = saved.newCounts
        books = saved.books ?? []
        libraries = saved.libraries ?? []
    }

    private func save() {
        guard let server else { return }
        let saved = Saved(server: server, shows: shows, newEpisodes: newEpisodes, continueListening: continueListening,
                          progress: progress, transcriptStatus: transcriptStatus, newCounts: newCounts, books: books, libraries: libraries)
        if let data = try? JSONEncoder().encode(saved) { try? cache.save(data, for: "home") }
    }

    private static func isOffline(_ error: any Error) -> Bool {
        switch error as? ConnectionError {
        case .unreachable, .timeout: true
        default: false
        }
    }

    /// A show's episodes, newest first (and their transcript states).
    /// Offline, the saved copy of the show, or else just its downloaded episodes.
    func loadShow(_ itemId: String) async {
        guard let environment, let client = environment.audiobookshelfClient() else { return }
        restoreSaved()
        if showEpisodes[itemId] == nil, let data = try? cache.data(for: "show:\(itemId)"),
           let saved = try? JSONDecoder().decode([AudiobookshelfEpisode].self, from: data) {
            showEpisodes[itemId] = saved
        }
        do {
            var item = try await client.item(id: itemId)
            let episodes = (item.media.episodes ?? []).sorted { ($0.publishedAt ?? 0) > ($1.publishedAt ?? 0) }
            showEpisodes[itemId] = episodes
            isOffline = false
            if let data = try? JSONEncoder().encode(episodes) { try? cache.save(data, for: "show:\(itemId)") }
            item.media.episodes = nil
            if let index = shows.firstIndex(where: { $0.id == itemId }) { shows[index] = item } else { shows.append(item) }
            await loadStatuses(episodes)
        } catch let failure {
            if !failure.isCancellation { error = failure.localizedDescription }
            isOffline = Self.isOffline(failure)
            if showEpisodes[itemId] == nil {
                showEpisodes[itemId] = environment.downloadedEntries.filter { $0.itemId == itemId }.map(\.episode)
            }
        }
    }

    /// A book with its chapters and tracks: fetched (and saved for offline), or the saved copy.
    @discardableResult
    func loadBook(_ itemId: String) async -> AudiobookshelfItem? {
        restoreSaved()
        if let book = await details(itemId) {
            if let episode = AudiobookshelfEpisode.wholeBook(book) { await loadStatuses([episode]) }
            return book
        }
        return nil
    }

    private func details(_ itemId: String) async -> AudiobookshelfItem? {
        if bookDetails[itemId] == nil, let data = try? cache.data(for: "book:\(itemId)"),
           let saved = try? JSONDecoder().decode(AudiobookshelfItem.self, from: data) {
            bookDetails[itemId] = saved
        }
        guard let client = environment?.audiobookshelfClient() else { return bookDetails[itemId] }
        do {
            let book = try await client.item(id: itemId)
            bookDetails[itemId] = book
            if let data = try? JSONEncoder().encode(book) { try? cache.save(data, for: "book:\(itemId)") }
        } catch let failure {
            if !failure.isCancellation { isOffline = Self.isOffline(failure) }
        }
        return bookDetails[itemId]
    }

    func loadStatuses(_ episodes: [AudiobookshelfEpisode]) async {
        guard let kaku = environment?.kakuClient(), !episodes.isEmpty else { return }
        let missing = episodes.filter { transcriptStatus[$0.key] != .done }
        guard !missing.isEmpty else { return }
        if let statuses = try? await kaku.status(missing.map { (itemId: $0.libraryItemId, episodeId: $0.id) }) {
            transcriptStatus.merge(statuses) { $1 }
        }
    }

    func setStatus(_ status: KakuStatus, for key: String) {
        transcriptStatus[key] = status
    }

    /// Keeps the shelves right while listening, before Audiobookshelf is asked again.
    func update(progress update: AudiobookshelfProgress) {
        progress[update.key] = update
        func refreshed(_ entries: [EpisodeEntry]) -> [EpisodeEntry] {
            entries.map { $0.id == update.key ? EpisodeEntry(episode: $0.episode, showTitle: $0.showTitle, progress: update) : $0 }
        }
        newEpisodes = refreshed(newEpisodes)
        continueListening = refreshed(continueListening)
    }
}
