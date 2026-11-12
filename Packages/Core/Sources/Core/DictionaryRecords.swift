import Foundation
import GRDB

/// An installed Yomitan dictionary. The content is in hoshidicts' format in a folder named
/// `folder` (after `id` until it's updated); this row holds what the app shows and how it's used.
public struct DictionaryRecord: Codable, Equatable, Identifiable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "dictionary"

    public var id: String
    public var title: String
    public var revision: String?
    public var attribution: String?
    public var hasTerms: Bool
    public var hasFrequencies: Bool
    public var hasPitches: Bool
    public var hasKanji: Bool
    public var termCount: Int
    public var metaCount: Int
    public var kanjiCount: Int
    public var mediaCount: Int
    public var bytes: Int
    public var enabled: Bool
    public var sortOrder: Int
    public var importedAt: Date
    /// The content's folder name; nil means `id`. An update installs beside the old folder.
    public var folder: String?

    public var folderName: String { folder ?? id }

    public init(
        id: String, title: String, revision: String? = nil, attribution: String? = nil,
        hasTerms: Bool = false, hasFrequencies: Bool = false, hasPitches: Bool = false, hasKanji: Bool = false,
        termCount: Int = 0, metaCount: Int = 0, kanjiCount: Int = 0, mediaCount: Int = 0, bytes: Int = 0,
        enabled: Bool = true, sortOrder: Int = 0, importedAt: Date = Date(), folder: String? = nil
    ) {
        self.id = id
        self.title = title
        self.revision = revision
        self.attribution = attribution
        self.hasTerms = hasTerms
        self.hasFrequencies = hasFrequencies
        self.hasPitches = hasPitches
        self.hasKanji = hasKanji
        self.termCount = termCount
        self.metaCount = metaCount
        self.kanjiCount = kanjiCount
        self.mediaCount = mediaCount
        self.bytes = bytes
        self.enabled = enabled
        self.sortOrder = sortOrder
        self.importedAt = importedAt
        self.folder = folder
    }
}

/// Where an installed dictionary came from and how it updates: from its own `index.json`
/// (Yomitan's `isUpdatable`, `indexUrl`, `downloadUrl`), and the recommended set's entry.
public struct DictionarySource: Codable, Equatable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "dictionarySource"

    public var dictionaryId: String
    /// The recommended set's id (`RecommendedDictionaries`); nil for imported dictionaries.
    public var catalogId: String?
    public var indexUrl: String?
    public var downloadUrl: String?
    public var isUpdatable: Bool
    public var checkedAt: Date?
    /// The newest revision the index named that a download didn't bring.
    public var undeliveredRevision: String?

    public init(dictionaryId: String, catalogId: String? = nil, indexUrl: String? = nil, downloadUrl: String? = nil,
                isUpdatable: Bool = false, checkedAt: Date? = nil, undeliveredRevision: String? = nil) {
        self.dictionaryId = dictionaryId
        self.catalogId = catalogId
        self.indexUrl = indexUrl
        self.downloadUrl = downloadUrl
        self.isUpdatable = isUpdatable
        self.checkedAt = checkedAt
        self.undeliveredRevision = undeliveredRevision
    }

    /// Updates itself: from the recommended set, or its index says so and says where.
    public var updates: Bool { (catalogId != nil || isUpdatable) && indexUrl != nil }
}

/// Where word audio comes from, tried in `sortOrder` (Yomitan's audio sources).
public struct AudioSourceRecord: Codable, Equatable, Identifiable, Hashable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "audioSource"

    public enum Kind: String, Codable, CaseIterable, Sendable {
        /// JapanesePod101's word audio (Yomitan's built-in source); `template` is unused.
        case jpod101
        /// A URL template that returns an audio file.
        case url
        /// A URL template that returns Yomitan's JSON list of audio sources (e.g. a local audio server).
        case json
    }

    public var id: Int64?
    public var kind: Kind
    public var name: String
    /// URL with `{term}` and `{reading}` placeholders.
    public var template: String
    public var enabled: Bool
    public var sortOrder: Int

    public init(id: Int64? = nil, kind: Kind, name: String, template: String, enabled: Bool = true, sortOrder: Int = 0) {
        self.id = id
        self.kind = kind
        self.name = name
        self.template = template
        self.enabled = enabled
        self.sortOrder = sortOrder
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

public struct LookupHistoryRecord: Codable, Equatable, Identifiable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "lookupHistory"

    public var id: Int64?
    public var query: String
    public var expression: String
    public var reading: String
    public var createdAt: Date

    public init(id: Int64? = nil, query: String, expression: String, reading: String, createdAt: Date = Date()) {
        self.id = id
        self.query = query
        self.expression = expression
        self.reading = reading
        self.createdAt = createdAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// Single-row settings for lookups.
public struct DictionarySettings: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "dictionarySettings"

    public var id = 1
    /// Frequency dictionary used to sort results; nil picks the first enabled one.
    public var frequencySortTitle: String?
    /// Keep Recommended Up to Date (Settings ▸ Dictionaries ▸ Updates).
    public var autoUpdate: Bool
    public var lastUpdateCheck: Date?
    /// Recommended dictionaries the user deleted: Add Recommended and setup leave them out.
    public var removedRecommended: [String]

    public init(frequencySortTitle: String? = nil, autoUpdate: Bool = true, lastUpdateCheck: Date? = nil,
                removedRecommended: [String] = []) {
        self.frequencySortTitle = frequencySortTitle
        self.autoUpdate = autoUpdate
        self.lastUpdateCheck = lastUpdateCheck
        self.removedRecommended = removedRecommended
    }

    enum CodingKeys: String, CodingKey { case id, frequencySortTitle, autoUpdate, lastUpdateCheck, removedRecommended }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(Int.self, forKey: .id) ?? 1
        frequencySortTitle = try container.decodeIfPresent(String.self, forKey: .frequencySortTitle)
        autoUpdate = try container.decodeIfPresent(Bool.self, forKey: .autoUpdate) ?? true
        lastUpdateCheck = try container.decodeIfPresent(Date.self, forKey: .lastUpdateCheck)
        // Stored as JSON text.
        let removed = try container.decodeIfPresent(String.self, forKey: .removedRecommended) ?? "[]"
        removedRecommended = (try? JSONDecoder().decode([String].self, from: Data(removed.utf8))) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(frequencySortTitle, forKey: .frequencySortTitle)
        try container.encode(autoUpdate, forKey: .autoUpdate)
        try container.encode(lastUpdateCheck, forKey: .lastUpdateCheck)
        let removed = (try? JSONEncoder().encode(removedRecommended)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        try container.encode(removed, forKey: .removedRecommended)
    }
}
