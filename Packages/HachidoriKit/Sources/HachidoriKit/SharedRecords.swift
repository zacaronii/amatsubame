import Foundation

/// The client's copy of the host's shared records: the six keys from the hello's snapshot, kept
/// current by `storage` frames, plus any lookup-count rows those frames carried. Read-only for the
/// client: changes are requests the host commits and broadcasts back (docs/hachidori.md section 1).
public struct SharedRecords: Equatable, Sendable {
    public static let snapshotKeys = ["dictionaryState", "options", "customDictionarySource", "dictionaryUpdates",
                                      "lookupStats", "wordStatusOverrides"]

    public private(set) var values: [String: JSONValue] = [:]

    public init(values: [String: JSONValue] = [:]) {
        self.values = values
    }

    /// A (re)connect: the snapshot replaces the shared keys as one batch. Count rows from before
    /// stay; rows of another generation are never read.
    public mutating func apply(snapshot: [String: JSONValue]) {
        for key in Self.snapshotKeys { values[key] = snapshot[key] }
    }

    public mutating func apply(changes: [String: JSONValue?]) {
        for (key, value) in changes { values[key] = value }
    }

    public var options: HostOptions { HostOptions(values["options"]) }

    public var dictionaries: [HostDictionary] {
        (values["dictionaryState"]?["dictionaries"]?.array ?? []).compactMap { try? $0.decode(HostDictionary.self) }
    }

    public var wordStatus: WordStatusOverrides {
        (try? values["wordStatusOverrides"]?.decode(WordStatusOverrides.self)) ?? WordStatusOverrides()
    }

    public var lookupStats: LookupStatsDescriptor {
        (try? values["lookupStats"]?.decode(LookupStatsDescriptor.self)) ?? LookupStatsDescriptor()
    }

    /// The personal dictionary's source: one `term, reading, definition` entry per line.
    public var customDictionaryText: String { values["customDictionarySource"]?["text"]?.string ?? "" }

    /// A count row seen in a `storage` frame for the current generation, if any. Rows aren't in the
    /// snapshot; `hd_lookup_stats_read` asks for one.
    public func lookupCount(term: String, reading: String) -> HostLookupCount? {
        guard let generation = lookupStats.generation else { return nil }
        let prefix = "lookupStats:\"\(generation)\":"
        let term = HostLookupCount.normalized(term), reading = HostLookupCount.normalized(reading)
        for (key, value) in values where key.hasPrefix(prefix) {
            if let row = try? value.decode(HostLookupCount.self), row.term == term, row.reading == reading { return row }
        }
        return nil
    }
}

/// The settings a lookup client follows, with Hachidori's defaults (`reader-options.js`
/// `DEFAULT_OPTIONS`) for keys the host hasn't stored: it stores only what was changed.
/// `options.anki` (the host's AnkiConnect URL and key) is deliberately not exposed.
public struct HostOptions: Equatable, Sendable {
    public var revision: Int
    public var maxResults: Int
    public var scanLength: Int
    /// A dictionary title, or "" for none.
    public var frequencyDictionary: String
    /// "auto", "ascending", "descending" or "disabled".
    public var frequencyOrder: String
    public var showLookupCounts: Bool
    public var showCompactDefinitionSummary: Bool
    public var compactDefinitionSummaryCount: Int
    public var compactDefinitionSummaryDictionary: String
    public var popupOpacityPercent: Int
    public var kanjiClickDictionary: String
    public var pitchAccentFuriganaDictionary: String

    public init(_ value: JSONValue?) {
        revision = value?["revision"]?.int ?? 0
        maxResults = value?["maxResults"]?.int ?? 32
        scanLength = value?["scanLength"]?.int ?? 16
        frequencyDictionary = value?["frequencyDictionary"]?.string ?? ""
        frequencyOrder = value?["frequencyOrder"]?.string ?? "auto"
        showLookupCounts = value?["showLookupCounts"]?.bool ?? true
        showCompactDefinitionSummary = value?["showCompactDefinitionSummary"]?.bool ?? false
        compactDefinitionSummaryCount = value?["compactDefinitionSummaryCount"]?.int ?? 3
        compactDefinitionSummaryDictionary = value?["compactDefinitionSummaryDictionary"]?.string ?? ""
        popupOpacityPercent = value?["popupOpacityPercent"]?.int ?? 85
        kanjiClickDictionary = value?["kanjiClickDictionary"]?.string ?? ""
        pitchAccentFuriganaDictionary = value?["pitchAccentFuriganaDictionary"]?.string ?? ""
    }
}

/// One installed dictionary on the host, in the host's order.
public struct HostDictionary: Equatable, Sendable, Decodable {
    public var id: String
    public var title: String
    public var displayName: String?
    public var enabled: Bool
    public var revision: String?
    public var termCount: Int?
    public var frequencyCount: Int?
    public var pitchCount: Int?
    public var kanjiCount: Int?
    public var isUpdatable: Bool?
    public var indexUrl: String?
    public var downloadUrl: String?

    public var name: String { displayName ?? title }
}

/// Words marked known or ignored by hand (each headword is in at most one list).
public struct WordStatusOverrides: Equatable, Sendable, Decodable {
    public var revision = 0
    public var known: [String] = []
    public var ignored: [String] = []

    public init(revision: Int = 0, known: [String] = [], ignored: [String] = []) {
        self.revision = revision
        self.known = known
        self.ignored = ignored
    }
}

/// Names the current set of counts; a reset starts a new generation.
public struct LookupStatsDescriptor: Equatable, Sendable, Decodable {
    public var generation: String?
    public var revision = 0

    public init(generation: String? = nil, revision: Int = 0) {
        self.generation = generation
        self.revision = revision
    }
}

/// How often the host has counted a headword. Times are epoch milliseconds, the host's clock.
public struct HostLookupCount: Equatable, Sendable, Decodable {
    public var term: String
    public var reading: String
    public var lookupCount: Int
    public var firstLookedUpAt: Double?
    public var lastLookedUpAt: Double?

    /// Hachidori's key: trimmed and NFC.
    public static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
    }
}
