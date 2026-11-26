@testable import Core
import Foundation
import GRDB
import Testing

/// Updating from a released build keeps everything: a database made by each release (its last
/// migration), with a row in every table, takes the rest of the migrations without an error, and
/// every row is still there with the same values in the columns it still has.
@Suite struct DatabaseUpgradeTests {
    /// The last migration of each release and of the last Dev build before this test.
    static let releases = [
        "v31_dictionary_source",   // 0.1.0 – 0.2.1
        "v40_watch_live_text",     // 0.3.0
        "v70_read_along_source",   // Dev build 202611250439
    ]

    @Test(arguments: releases)
    func updatingKeepsEveryRow(from release: String) throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: release)
        let seeded = try queue.write { db in try Self.seed(db) }
        #expect(seeded.count > 30, "most tables seeded at \(release)")
        let before = try queue.read { db in
            try Dictionary(uniqueKeysWithValues: seeded.map { ($0, try Row.fetchOne(db, sql: "SELECT * FROM \"\($0)\"")!) })
        }

        try AppDatabase.migrator.migrate(queue)

        try queue.read { db in
            for table in seeded.sorted() {
                #expect(try db.tableExists(table), "\(table) still there after updating from \(release)")
                guard try db.tableExists(table) else { continue }
                #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \"\(table)\"") == 1, "\(table) keeps its row")
                guard let after = try Row.fetchOne(db, sql: "SELECT * FROM \"\(table)\""), let old = before[table] else { continue }
                for column in old.columnNames {
                    #expect(after.hasColumn(column), "\(table).\(column) kept")
                    if after.hasColumn(column) {
                        #expect(after[column] as DatabaseValue == old[column] as DatabaseValue, "\(table).\(column) unchanged")
                    }
                }
            }
        }
    }

    /// One made-up row in every ordinary table (not the search indexes' own tables), with a value
    /// of each column's type; tables whose parent wasn't there yet get a second try.
    private static func seed(_ db: Database) throws -> [String] {
        let virtual = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table' AND sql LIKE '%VIRTUAL%'")
        let tables = try String.fetchAll(db, sql: """
            SELECT name FROM sqlite_master WHERE type='table' AND sql NOT LIKE '%VIRTUAL%'
            AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'grdb_%' ORDER BY name
            """).filter { table in !virtual.contains { table.hasPrefix($0 + "_") } }
        var seeded: [String] = []
        for table in tables + tables where !seeded.contains(table) {
            let columns = try db.columns(in: table)
            let values = columns.map { column -> String in
                let type = column.type.uppercased()
                if type.contains("INT") || type.contains("BOOL") { return "1" }
                if type.contains("REAL") || type.contains("DOUBLE") { return "1.5" }
                if type.contains("BLOB") { return "x'7b7d'" }
                if type.contains("DATE") { return "'2026-01-01 00:00:00.000'" }
                return "'\(table).\(column.name)'"
            }
            let names = columns.map { "\"\($0.name)\"" }.joined(separator: ",")
            if (try? db.execute(sql: "INSERT INTO \"\(table)\" (\(names)) VALUES (\(values.joined(separator: ",")))")) != nil {
                seeded.append(table)
            }
        }
        return seeded
    }

    /// Anki settings saved by 0.2.0 (only the keys it had) still load, with the later ones defaulted.
    @Test func ankiSettingsFromTheFirstReleaseLoad() throws {
        let saved = #"{"deck":"Test Deck","noteType":"Lapis","fields":{"Expression":{"slot":{"_0":"expression"}},"IsSentenceCard":{"constant":{"_0":"x"}}},"tags":["test"]}"#
        let settings = try JSONDecoder().decode(AnkiSettings.self, from: Data(saved.utf8))
        #expect(settings.deck == "Test Deck")
        #expect(settings.noteType == "Lapis")
        #expect(settings.tags == ["test"])
        #expect(settings.fields["Expression"] == .slot(.expression))
        #expect(settings.fields["IsSentenceCard"] == .constant("x"))
        #expect(settings.pictureMaxPixels == 1600)
    }
}
