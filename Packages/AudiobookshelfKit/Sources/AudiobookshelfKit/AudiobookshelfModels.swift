import Foundation

// Shapes verified against Audiobookshelf 2.36.1 (2026-11-05). Times named `…At` and
// `lastUpdate` are milliseconds since 1970; durations and positions are seconds.
// Shows and episodes are also Encodable, so an app can keep the last answer for offline use.

public struct AudiobookshelfStatus: Decodable, Equatable, Sendable {
    public var app: String?
    public var serverVersion: String
    public var isInit: Bool?
}

public struct AudiobookshelfLibrary: Codable, Equatable, Hashable, Sendable, Identifiable {
    public enum MediaType: String, Codable, Sendable {
        case podcast, book
    }

    public var id: String
    public var name: String
    public var mediaType: MediaType
}

public struct AudiobookshelfUser: Decodable, Equatable, Sendable {
    public var id: String
    public var username: String
    public var type: String?
    public var mediaProgress: [AudiobookshelfProgress]
    /// Only in sign-in and refresh answers.
    public var accessToken: String?
    public var refreshToken: String?
}

/// The listener's place in one episode.
public struct AudiobookshelfProgress: Codable, Equatable, Hashable, Sendable {
    public var libraryItemId: String
    public var episodeId: String?
    public var duration: Double
    /// 0–1.
    public var progress: Double
    public var currentTime: Double
    public var isFinished: Bool
    public var hideFromContinueListening: Bool?
    /// Milliseconds since 1970.
    public var lastUpdate: Double

    public init(libraryItemId: String, episodeId: String?, duration: Double, progress: Double, currentTime: Double,
                isFinished: Bool, hideFromContinueListening: Bool? = nil, lastUpdate: Double) {
        self.libraryItemId = libraryItemId
        self.episodeId = episodeId
        self.duration = duration
        self.progress = progress
        self.currentTime = currentTime
        self.isFinished = isFinished
        self.hideFromContinueListening = hideFromContinueListening
        self.lastUpdate = lastUpdate
    }

    public var updatedAt: Date { Date(timeIntervalSince1970: lastUpdate / 1000) }
    public var key: String { Self.key(itemId: libraryItemId, episodeId: episodeId) }
    /// "<item>/<episode>", or the item alone for a book (no episode, or an empty one).
    public static func key(itemId: String, episodeId: String?) -> String {
        guard let episodeId, !episodeId.isEmpty else { return itemId }
        return "\(itemId)/\(episodeId)"
    }

    /// The path under `progress/`, `transcripts/` and `clips/`: the same as the key.
    public static func path(itemId: String, episodeId: String) -> String { key(itemId: itemId, episodeId: episodeId) }
}

public struct AudiobookshelfAudioFile: Codable, Equatable, Hashable, Sendable {
    /// The file's inode: the download and stream URLs name it.
    public var ino: String
    public var duration: Double?
    public var mimeType: String?
    /// A description such as "MP2/3 (MPEG audio layer 2/3)", not a file extension.
    public var format: String?
    public var metadata: Metadata?

    public struct Metadata: Codable, Equatable, Hashable, Sendable {
        public var filename: String?
        /// ".mp3", with the dot.
        public var ext: String?
    }

    /// A safe extension for saving the file: from its name on the server, else its MIME type.
    public var fileExtension: String {
        let fromName = (metadata?.ext ?? metadata?.filename.map { ($0 as NSString).pathExtension })?
            .trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        if let fromName, !fromName.isEmpty, fromName.allSatisfy({ $0.isLetter || $0.isNumber }) { return fromName }
        switch mimeType {
        case "audio/mp4", "audio/x-m4a", "audio/m4b": return "m4a"
        case "audio/aac": return "aac"
        case "audio/ogg": return "ogg"
        case "audio/flac": return "flac"
        case "audio/wav", "audio/x-wav": return "wav"
        default: return "mp3"
        }
    }
}

/// A show's or a book's metadata (a book has `authorName` and `narratorName`).
public struct AudiobookshelfShowMetadata: Codable, Equatable, Hashable, Sendable {
    public var title: String
    public var author: String?
    public var description: String?
    public var language: String?
    public var authorName: String?
    public var narratorName: String?
}

/// A book chapter on the item's timeline (seconds).
public struct AudiobookshelfChapter: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: Int
    public var start: Double
    public var end: Double
    public var title: String
}

/// One audio file of a book on its single timeline.
public struct AudiobookshelfTrack: Codable, Equatable, Hashable, Sendable {
    public var index: Int?
    public var ino: String
    public var startOffset: Double
    public var duration: Double
    public var mimeType: String?
}

public struct AudiobookshelfEpisode: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: String
    public var libraryItemId: String
    public var title: String
    public var description: String?
    /// "312", or empty.
    public var episode: String?
    public var season: String?
    public var publishedAt: Double?
    public var addedAt: Double?
    public var duration: Double?
    public var size: Int?
    public var audioFile: AudiobookshelfAudioFile?
    /// In `recent-episodes` answers: the show it belongs to.
    public var podcast: Podcast?

    public struct Podcast: Codable, Equatable, Hashable, Sendable {
        public var metadata: AudiobookshelfShowMetadata
    }

    public var key: String { AudiobookshelfProgress.key(itemId: libraryItemId, episodeId: id) }
    public var publishedDate: Date? { publishedAt.map { Date(timeIntervalSince1970: $0 / 1000) } }
    /// The episode's length: from the item's own field, else its audio file.
    public var length: Double? { duration ?? audioFile?.duration }
}

extension AudiobookshelfEpisode {
    /// A whole book as one long "episode" with an empty id, the way Kaku keys it: progress,
    /// transcripts, downloads and marks then work as for podcasts. Needs the expanded item
    /// (its tracks); a book of several files gets its first, and apps check `numTracks`.
    public static func wholeBook(_ book: AudiobookshelfItem) -> AudiobookshelfEpisode? {
        guard book.isBook, let track = book.media.tracks?.min(by: { ($0.index ?? 0) < ($1.index ?? 0) }) else { return nil }
        let duration = book.media.duration ?? book.media.tracks?.reduce(0) { $0 + $1.duration } ?? track.duration
        return AudiobookshelfEpisode(
            id: "", libraryItemId: book.id, title: book.title, description: book.media.metadata.description,
            episode: nil, season: nil, publishedAt: book.addedAt, addedAt: book.addedAt, duration: duration, size: book.media.size,
            audioFile: AudiobookshelfAudioFile(ino: track.ino, duration: duration, mimeType: track.mimeType, format: nil, metadata: nil),
            podcast: nil)
    }
}

/// A podcast or a book in a library.
public struct AudiobookshelfItem: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: String
    public var libraryId: String
    public var mediaType: AudiobookshelfLibrary.MediaType
    public var media: Media
    public var addedAt: Double?
    public var updatedAt: Double?
    /// In `items-in-progress` answers: the episode being listened to.
    public var recentEpisode: AudiobookshelfEpisode?
    public var progressLastUpdate: Double?

    public struct Media: Codable, Equatable, Hashable, Sendable {
        public var metadata: AudiobookshelfShowMetadata
        public var numEpisodes: Int?
        /// Only when the item is fetched on its own (`expanded=1`).
        public var episodes: [AudiobookshelfEpisode]?
        /// Books: the whole length, its size, and (expanded) chapters and tracks.
        public var duration: Double?
        public var size: Int?
        public var numTracks: Int?
        public var chapters: [AudiobookshelfChapter]?
        public var tracks: [AudiobookshelfTrack]?
    }

    public var title: String { media.metadata.title }
    public var isBook: Bool { mediaType == .book }
}

struct AudiobookshelfItemPage: Decodable {
    var results: [AudiobookshelfItem]
    var total: Int
}

struct AudiobookshelfLibraries: Decodable {
    var libraries: [AudiobookshelfLibrary]
}

struct AudiobookshelfEpisodes: Decodable {
    var episodes: [AudiobookshelfEpisode]
}

struct AudiobookshelfItemsInProgress: Decodable {
    var libraryItems: [AudiobookshelfItem]
}

struct AudiobookshelfLogin: Decodable {
    var user: AudiobookshelfUser
}
