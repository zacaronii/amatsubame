import Foundation
import GRDB

/// How often one headword was looked up: Hachidori's lookup statistics row
/// (`{term, reading, lookupCount, firstLookedUpAt, lastLookedUpAt}`, docs/hachidori.md).
public struct LookupCountRecord: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "lookupCount"

    /// The dictionary headword and its reading (trimmed, NFC), not the text that was tapped.
    public var term: String
    public var reading: String
    public var lookupCount: Int
    public var firstLookedUpAt: Date
    public var lastLookedUpAt: Date

    public init(term: String, reading: String, lookupCount: Int, firstLookedUpAt: Date, lastLookedUpAt: Date) {
        self.term = term
        self.reading = reading
        self.lookupCount = lookupCount
        self.firstLookedUpAt = firstLookedUpAt
        self.lastLookedUpAt = lastLookedUpAt
    }
}

/// Settings ▸ Popup, shared by every app like the dictionaries.
public struct PopupSettings: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "popupSettings"

    public var id = 1
    /// Count lookups and show "Looked up N times" (Hachidori's Lookup history switch, on by
    /// default). Off keeps the counts but stops new ones.
    public var showLookupCounts: Bool
    /// Hachidori's compact definition summary: brief definitions beside each headword. Off by
    /// default, as in Hachidori.
    public var showCompactDefinitionSummary: Bool
    /// How many snippets (1–6, Hachidori's default 3).
    public var compactDefinitionSummaryCount: Int
    /// The dictionary the summary comes from first (its title); nil picks the first that has one.
    public var compactDefinitionSummaryDictionary: String?
    /// Hachidori's Background opacity: how much of what's behind the popup shows through
    /// (0–100 %, 85 by default). Text stays opaque.
    public var backgroundOpacityPercent: Int
    /// On the Mac: looking a word up by pointing at it (Yomu's books, Miru's subtitles, Kiku's
    /// transcript) while this key is held, without a click. Not one of Hachidori's options.
    public var hoverLookup: HoverLookup

    /// The key that turns pointing at a word into a lookup.
    public enum HoverLookup: String, Codable, CaseIterable, Sendable, DatabaseValueConvertible {
        /// Click only.
        case off
        case shift, option, control, command
        /// No key: pointing alone looks the word up.
        case always
    }

    /// A new installation's settings, written once (Hachidori's `FIRST_INSTALL_OPTIONS`): brief
    /// definitions on, two snippets. Existing setups keep the defaults above.
    public static let firstInstall = PopupSettings(showCompactDefinitionSummary: true, compactDefinitionSummaryCount: 2)

    public init(showLookupCounts: Bool = true, showCompactDefinitionSummary: Bool = false,
                compactDefinitionSummaryCount: Int = 3, compactDefinitionSummaryDictionary: String? = nil,
                backgroundOpacityPercent: Int = 85, hoverLookup: HoverLookup = .shift) {
        self.showLookupCounts = showLookupCounts
        self.showCompactDefinitionSummary = showCompactDefinitionSummary
        self.compactDefinitionSummaryCount = compactDefinitionSummaryCount
        self.compactDefinitionSummaryDictionary = compactDefinitionSummaryDictionary
        self.backgroundOpacityPercent = backgroundOpacityPercent
        self.hoverLookup = hoverLookup
    }
}

/// Lookup counts and the popup's settings, in the setup's database (shared between the apps
/// when they share a setup).
public struct LookupCountStore: Sendable {
    let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    /// Hachidori's key: trimmed and NFC-normalized, so the same word always meets its row.
    public static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
    }

    /// One lookup of `term`/`reading`: adds 1 and returns the row.
    @discardableResult
    public func record(term: String, reading: String, at date: Date = Date()) throws -> LookupCountRecord {
        let term = Self.normalized(term), reading = Self.normalized(reading)
        return try database.writer.write { db in
            var row = try LookupCountRecord.fetchOne(db, key: ["term": term, "reading": reading])
                ?? LookupCountRecord(term: term, reading: reading, lookupCount: 0, firstLookedUpAt: date, lastLookedUpAt: date)
            row.lookupCount += 1
            row.lastLookedUpAt = date
            try row.save(db)
            return row
        }
    }

    /// Sets a word's count to the linked host's (its count plus what's still queued for it), so
    /// it shows the same number offline.
    public func setCount(term: String, reading: String, to count: Int, at date: Date = Date()) throws {
        let term = Self.normalized(term), reading = Self.normalized(reading)
        try database.writer.write { db in
            var row = try LookupCountRecord.fetchOne(db, key: ["term": term, "reading": reading])
                ?? LookupCountRecord(term: term, reading: reading, lookupCount: 0, firstLookedUpAt: date, lastLookedUpAt: date)
            guard row.lookupCount != count else { return }
            row.lookupCount = count
            try row.save(db)
        }
    }

    public func count(term: String, reading: String) throws -> Int {
        try database.reader.read { db in
            try LookupCountRecord.fetchOne(db, key: ["term": Self.normalized(term), "reading": Self.normalized(reading)])?.lookupCount ?? 0
        }
    }

    /// Settings ▸ Popup ▸ Reset Lookup Counts: every word starts again from 1.
    public func reset() throws {
        _ = try database.writer.write { try LookupCountRecord.deleteAll($0) }
    }

    public func settings() throws -> PopupSettings {
        try database.reader.read { try PopupSettings.fetchOne($0, key: 1) } ?? PopupSettings()
    }

    /// Writes `PopupSettings.firstInstall` unless settings were already saved. Returns whether it did.
    @discardableResult
    public func saveFirstInstallSettings() throws -> Bool {
        try database.writer.write { db in
            guard try PopupSettings.fetchOne(db, key: 1) == nil else { return false }
            try PopupSettings.firstInstall.save(db)
            return true
        }
    }

    public func save(_ settings: PopupSettings) throws {
        try database.writer.write { try settings.save($0) }
    }
}

/// Lookups of one headword still to count on the Hachidori host (`OutboxJobKind.hachidoriLookupCount`).
/// The host has no batch form (docs/hachidori.md section 4), so they go one
/// `hd_lookup_stats_record` at a time and get the time they're sent.
public struct HostLookupCountJob: Codable, Equatable, Sendable {
    public var term: String
    public var reading: String
    public var count: Int

    public init(term: String, reading: String, count: Int) {
        self.term = term
        self.reading = reading
        self.count = count
    }
}

extension OutboxStore {
    static func hostCountKey(term: String, reading: String) -> String {
        "hachidori.count:\(LookupCountStore.normalized(term))\t\(LookupCountStore.normalized(reading))"
    }

    /// Queues one lookup for the host: added to the word's waiting job, or a new job when there's
    /// none (or it's being sent).
    public func queueHostLookupCount(term: String, reading: String) throws {
        let key = Self.hostCountKey(term: term, reading: reading)
        let now = now()
        try database.writer.write { db in
            if var job = try OutboxJob.filter(Column("coalesceKey") == key && Column("state") == OutboxJobState.pending).fetchOne(db),
               var payload = try? job.decodePayload(HostLookupCountJob.self) {
                payload.count += 1
                job.payload = try JSONEncoder().encode(payload)
                job.updatedAt = now
                try job.update(db)
                return
            }
            let payload = HostLookupCountJob(term: LookupCountStore.normalized(term), reading: LookupCountStore.normalized(reading), count: 1)
            var job = OutboxJob(kind: .hachidoriLookupCount, coalesceKey: key, payload: try JSONEncoder().encode(payload), state: .pending,
                                attempts: 0, lastError: nil, nextAttemptAt: now, createdAt: now, updatedAt: now)
            try job.insert(db)
        }
    }

    /// Lookups of a word not yet counted on the host (waiting or being sent).
    public func queuedHostLookupCount(term: String, reading: String) throws -> Int {
        let key = Self.hostCountKey(term: term, reading: reading)
        return try database.reader.read { db in
            try OutboxJob.filter(Column("coalesceKey") == key)
                .filter([OutboxJobState.pending.rawValue, OutboxJobState.inFlight.rawValue].contains(Column("state")))
                .fetchAll(db)
                .reduce(0) { $0 + ((try? $1.decodePayload(HostLookupCountJob.self))?.count ?? 0) }
        }
    }
}
