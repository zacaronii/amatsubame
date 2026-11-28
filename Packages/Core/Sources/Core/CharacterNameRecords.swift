import Foundation
import GRDB

/// A series' cast from AniList, as fetched (Packages/Names): the characters as JSON, kept so
/// opening the series again needs no network until it's 30 days old.
public struct CharacterCastRecord: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "characterCast"
    /// AniList's media: "MANGA:118586", "ANIME:154587".
    public var mediaKey: String
    public var title: String
    public var fetchedAt: Date
    public var characters: Data

    public init(mediaKey: String, title: String, fetchedAt: Date, characters: Data) {
        self.mediaKey = mediaKey
        self.title = title
        self.fetchedAt = fetchedAt
        self.characters = characters
    }
}

/// Which AniList media a series of ours is (a Kavita series, a Jellyfin show), and how that
/// was found. `mediaKey` nil: no match yet, and the user is asked to pick.
public struct CharacterNameMatch: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "characterNameMatch"
    public enum Source: String, Codable, Sendable {
        /// The server had the AniList id (Kavita's `aniListId`, Jellyfin's AniList provider id).
        case server
        /// Through another id: Kavita's MAL id, MangaBaka, AniDB.
        case linked
        /// AniList's title search, with a single strict match.
        case search
        /// The user picked it.
        case picked
    }

    /// "kavita:<server>:<series id>", "jellyfin:<server>:<series id>".
    public var seriesKey: String
    public var mediaKey: String?
    public var source: Source
    /// The series' own title (for Settings).
    public var title: String
    public var matchedAt: Date

    public init(seriesKey: String, mediaKey: String?, source: Source, title: String, matchedAt: Date = Date()) {
        self.seriesKey = seriesKey
        self.mediaKey = mediaKey
        self.source = source
        self.title = title
        self.matchedAt = matchedAt
    }
}

/// The series each app has open: the names dictionary holds these casts.
public struct CharacterNameOpenSeries: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "characterNameOpenSeries"
    /// "yomu", "miru".
    public var app: String
    public var seriesKey: String
    public var openedAt: Date

    public init(app: String, seriesKey: String, openedAt: Date = Date()) {
        self.app = app
        self.seriesKey = seriesKey
        self.openedAt = openedAt
    }
}

/// Settings ▸ Dictionaries ▸ Character Names (one row).
public struct CharacterNameSettings: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "characterNameSettings"
    public var id = 1
    public var enabled = true

    public init(enabled: Bool = true) {
        self.enabled = enabled
    }
}
