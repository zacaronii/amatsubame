import AudiobookshelfKit
import Core
import Foundation

/// One row of a CarPlay list, as plain data: `KikuCarPlay` turns it into a `CPListItem`.
struct CarPlayRow: Equatable {
    enum Action: Equatable {
        case play(EpisodeEntry)
        /// A book: its details (chapters, tracks) are loaded first.
        case playBook(itemId: String)
        case openLibrary(AudiobookshelfLibrary)
        case openShow(itemId: String, title: String)
        case openDownloaded
        case seek(Double)
        /// A note ("12 more on your iPhone"): does nothing.
        case none
    }

    var title: String
    var detail: String?
    /// How far it's been listened, 0…1 (shown as the row's progress bar); nil when not started.
    var progress: Double?
    /// Whose cover to show (an Audiobookshelf item).
    var artworkItemId: String?
    var action: Action
    var isPlaying = false
}

struct CarPlaySection: Equatable {
    var title: String?
    var rows: [CarPlayRow]
}

/// What Kiku shows in CarPlay (the Listen Now and Library tabs and the lists below them), built
/// from the same library data as the app's tabs. No transcripts: they're not for reading while driving.
enum CarPlaySections {
    // MARK: Listen Now

    /// Continue (in-progress books and episodes), New Episodes and Recently Added (books), as in
    /// the Listen tab; a section with nothing in it is left out.
    static func listenNow(continueListening: [EpisodeEntry], newEpisodes: [EpisodeEntry], recentBooks: [AudiobookshelfItem] = [],
                          playingKey: String?) -> [CarPlaySection] {
        let continuing = Set(continueListening.map(\.id))
        return [
            CarPlaySection(title: "Continue", rows: continueListening.map { row($0, playingKey: playingKey, detail: continueDetail($0)) }),
            CarPlaySection(title: "New Episodes", rows: newEpisodes.filter { !continuing.contains($0.id) }
                .map { row($0, playingKey: playingKey, detail: $0.showTitle) }),
            CarPlaySection(title: "Recently Added", rows: recentBooks.filter { !continuing.contains($0.id) }.map {
                CarPlayRow(title: $0.title, detail: $0.media.metadata.authorName, artworkItemId: $0.id, action: .playBook(itemId: $0.id),
                           isPlaying: $0.id == playingKey)
            }),
        ].filter { !$0.rows.isEmpty }
    }

    private static func continueDetail(_ entry: EpisodeEntry) -> String {
        let left = "\(entry.timeLeft.lengthText) left"
        return entry.collectionTitle.isEmpty || entry.isBook ? left : "\(entry.showTitle) · \(left)"
    }

    // MARK: Library

    /// The libraries not hidden in Settings, then Downloaded (what plays with no signal).
    static func libraries(_ libraries: [AudiobookshelfLibrary], hidden: Set<String>, downloadedCount: Int) -> [CarPlaySection] {
        var sections: [CarPlaySection] = []
        let shown = libraries.filter { !hidden.contains($0.id) }
        if !shown.isEmpty {
            sections.append(CarPlaySection(title: nil, rows: shown.map {
                CarPlayRow(title: $0.name, detail: $0.mediaType == .book ? "Audiobooks" : "Podcasts", action: .openLibrary($0))
            }))
        }
        sections.append(CarPlaySection(title: nil, rows: [
            CarPlayRow(title: "Downloaded", detail: downloadedCount == 0 ? "Nothing downloaded" : "\(downloadedCount) on this iPhone",
                       action: .openDownloaded)
        ]))
        return sections
    }

    /// A library's shows or books, by title.
    static func items(_ items: [AudiobookshelfItem], progress: [String: AudiobookshelfProgress], playingItemId: String?) -> [CarPlaySection] {
        let rows = items.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }.map { item in
            if item.isBook {
                let listened = progress[item.id].flatMap { $0.duration > 0 && $0.currentTime > 0 ? min($0.currentTime / $0.duration, 1) : nil }
                return CarPlayRow(title: item.title, detail: item.media.metadata.authorName, progress: listened,
                                  artworkItemId: item.id, action: .playBook(itemId: item.id), isPlaying: item.id == playingItemId)
            }
            return CarPlayRow(title: item.title, detail: item.media.metadata.author, artworkItemId: item.id,
                              action: .openShow(itemId: item.id, title: item.title))
        }
        return rows.isEmpty ? [] : [CarPlaySection(title: nil, rows: rows)]
    }

    /// A show's episodes, newest first, or the downloaded ones.
    static func episodes(_ entries: [EpisodeEntry], playingKey: String?, showsShow: Bool = false) -> [CarPlaySection] {
        let rows = entries.map { entry in
            var parts: [String] = showsShow ? [entry.collectionTitle] : []
            if entry.isFinished {
                parts.append("Played")
            } else if entry.duration > 0 {
                parts.append(entry.isStarted ? "\(entry.timeLeft.lengthText) left" : entry.duration.lengthText)
            }
            return row(entry, playingKey: playingKey, detail: parts.filter { !$0.isEmpty }.joined(separator: " · "))
        }
        return rows.isEmpty ? [] : [CarPlaySection(title: nil, rows: rows)]
    }

    /// A book's chapters (Now Playing's Chapters button); tapping one goes to its start.
    static func chapters(_ chapters: [AudiobookshelfChapter], current: AudiobookshelfChapter?) -> [CarPlaySection] {
        let rows = chapters.map { chapter in
            CarPlayRow(title: chapter.title, detail: chapter.start.clockText, action: .seek(chapter.start), isPlaying: chapter == current)
        }
        return rows.isEmpty ? [] : [CarPlaySection(title: nil, rows: rows)]
    }

    private static func row(_ entry: EpisodeEntry, playingKey: String?, detail: String?) -> CarPlayRow {
        CarPlayRow(title: entry.episode.title, detail: detail, progress: entry.isStarted && !entry.isFinished ? entry.fraction : nil,
                   artworkItemId: entry.itemId, action: .play(entry), isPlaying: entry.id == playingKey)
    }

    // MARK: Limits

    /// Keeps within CarPlay's limits (`CPListTemplate.maximumSectionCount` and `maximumItemCount`,
    /// rows of all sections together) by cutting, not paging: a cut section ends with a note
    /// saying how many more there are on the iPhone, which counts as one of its rows.
    static func limited(_ sections: [CarPlaySection], maxItems: Int, maxSections: Int) -> [CarPlaySection] {
        var left = maxItems
        var result: [CarPlaySection] = []
        for section in sections.prefix(max(maxSections, 0)) where left > 0 {
            var section = section
            if section.rows.count > left {
                let kept = max(left - 1, 0)
                let more = section.rows.count - kept
                section.rows = Array(section.rows.prefix(kept))
                    + [CarPlayRow(title: "\(more) more on your iPhone", action: .none)]
            }
            left -= section.rows.count
            result.append(section)
        }
        return result
    }
}

/// Now Playing's speed button steps through the player's speeds and wraps around.
enum CarPlaySpeeds {
    static func next(after rate: Double, speeds: [Double] = ListenSettings.speeds) -> Double {
        speeds.first { $0 > rate + 0.01 } ?? speeds.first ?? 1
    }
}
