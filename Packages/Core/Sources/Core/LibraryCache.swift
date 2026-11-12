import Foundation
import GRDB

// Library cache records. Typed columns cover hierarchy, sorting and progress;
// `raw` keeps the full server DTO so later phases can read more fields without
// a migration. Populated starting in phase 1 (Kavita) and phase 6 (Jellyfin).

public struct KavitaLibraryRecord: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "kavitaLibrary"
    public var id: Int
    public var name: String
    public var type: Int?
    public var raw: Data?
    public var fetchedAt: Date
    public init(
        id: Int,
        name: String,
        type: Int? = nil,
        raw: Data? = nil,
        fetchedAt: Date
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.raw = raw
        self.fetchedAt = fetchedAt
    }
}

public struct KavitaSeriesRecord: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "kavitaSeries"
    public var id: Int
    public var libraryId: Int
    public var name: String
    public var sortName: String?
    public var format: Int?
    public var pages: Int?
    public var pagesRead: Int?
    public var lastReadAt: Date?
    public var raw: Data?
    public var fetchedAt: Date
    public init(
        id: Int,
        libraryId: Int,
        name: String,
        sortName: String? = nil,
        format: Int? = nil,
        pages: Int? = nil,
        pagesRead: Int? = nil,
        lastReadAt: Date? = nil,
        raw: Data? = nil,
        fetchedAt: Date
    ) {
        self.id = id
        self.libraryId = libraryId
        self.name = name
        self.sortName = sortName
        self.format = format
        self.pages = pages
        self.pagesRead = pagesRead
        self.lastReadAt = lastReadAt
        self.raw = raw
        self.fetchedAt = fetchedAt
    }
}

public struct KavitaVolumeRecord: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "kavitaVolume"
    public var id: Int
    public var seriesId: Int
    public var name: String?
    public var number: Double?
    public var pages: Int?
    public var pagesRead: Int?
    public var raw: Data?
    public var fetchedAt: Date
    public init(
        id: Int,
        seriesId: Int,
        name: String? = nil,
        number: Double? = nil,
        pages: Int? = nil,
        pagesRead: Int? = nil,
        raw: Data? = nil,
        fetchedAt: Date
    ) {
        self.id = id
        self.seriesId = seriesId
        self.name = name
        self.number = number
        self.pages = pages
        self.pagesRead = pagesRead
        self.raw = raw
        self.fetchedAt = fetchedAt
    }
}

public struct KavitaChapterRecord: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "kavitaChapter"
    public var id: Int
    public var volumeId: Int
    public var seriesId: Int
    public var title: String?
    public var number: String?
    public var sortOrder: Double?
    public var pages: Int?
    public var pagesRead: Int?
    public var isSpecial: Bool
    public var raw: Data?
    public var fetchedAt: Date
    public init(
        id: Int,
        volumeId: Int,
        seriesId: Int,
        title: String? = nil,
        number: String? = nil,
        sortOrder: Double? = nil,
        pages: Int? = nil,
        pagesRead: Int? = nil,
        isSpecial: Bool,
        raw: Data? = nil,
        fetchedAt: Date
    ) {
        self.id = id
        self.volumeId = volumeId
        self.seriesId = seriesId
        self.title = title
        self.number = number
        self.sortOrder = sortOrder
        self.pages = pages
        self.pagesRead = pagesRead
        self.isSpecial = isSpecial
        self.raw = raw
        self.fetchedAt = fetchedAt
    }
}

public struct JellyfinItemRecord: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "jellyfinItem"
    public var id: String
    public var parentId: String?
    public var seriesId: String?
    public var type: String
    public var name: String
    public var sortName: String?
    public var indexNumber: Int?
    public var parentIndexNumber: Int?
    public var runTimeTicks: Int64?
    public var playbackPositionTicks: Int64?
    public var played: Bool
    public var raw: Data?
    public var fetchedAt: Date
    public init(
        id: String,
        parentId: String? = nil,
        seriesId: String? = nil,
        type: String,
        name: String,
        sortName: String? = nil,
        indexNumber: Int? = nil,
        parentIndexNumber: Int? = nil,
        runTimeTicks: Int64? = nil,
        playbackPositionTicks: Int64? = nil,
        played: Bool,
        raw: Data? = nil,
        fetchedAt: Date
    ) {
        self.id = id
        self.parentId = parentId
        self.seriesId = seriesId
        self.type = type
        self.name = name
        self.sortName = sortName
        self.indexNumber = indexNumber
        self.parentIndexNumber = parentIndexNumber
        self.runTimeTicks = runTimeTicks
        self.playbackPositionTicks = playbackPositionTicks
        self.played = played
        self.raw = raw
        self.fetchedAt = fetchedAt
    }
}
