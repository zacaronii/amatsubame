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

    public init(showLookupCounts: Bool = true) {
        self.showLookupCounts = showLookupCounts
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

    public func save(_ settings: PopupSettings) throws {
        try database.writer.write { try settings.save($0) }
    }
}
