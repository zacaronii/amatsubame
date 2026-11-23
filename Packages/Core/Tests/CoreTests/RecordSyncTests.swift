@testable import Core
import Foundation
import GRDB
import Testing

/// Sync with iCloud's records between two devices: two databases and one folder (no iCloud).
@Suite struct RecordSyncTests {
    let folder = FileManager.default.temporaryDirectory.appending(path: "RecordSyncTests-\(UUID().uuidString)")

    /// A plain collection over a table the test makes: id → text.
    struct Notes: SyncedCollection {
        let name = "notes"
        func records(_ db: Database) throws -> [String: Data] {
            var result: [String: Data] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT id, text FROM testNote") { result[row["id"]] = Data((row["text"] as String).utf8) }
            return result
        }
        func apply(id: String, value: Data?, _ db: Database) throws {
            try db.execute(sql: "DELETE FROM testNote WHERE id = ?", arguments: [id])
            if let value { try db.execute(sql: "INSERT INTO testNote (id, text) VALUES (?, ?)", arguments: [id, String(decoding: value, as: UTF8.self)]) }
        }
    }

    final class Clock: @unchecked Sendable {
        var now: Date
        init(_ now: Date) { self.now = now }
    }

    struct Device {
        let id: String
        let database: AppDatabase
        let clock: Clock
        var sync: RecordSync { RecordSync(database: database, app: "yomu", collections: [Notes(), DailyGoalCollection(calendar: RecordSyncTests.utc)], now: { [clock] in clock.now }) }

        init(_ id: String, at date: Date) throws {
            self.id = id
            database = try AppDatabase.inMemory()
            clock = Clock(date)
            try database.writer.write { try $0.execute(sql: "CREATE TABLE testNote (id TEXT PRIMARY KEY, text TEXT NOT NULL)") }
        }

        func set(_ id: String, _ text: String?) throws {
            try database.writer.write { db in
                try db.execute(sql: "DELETE FROM testNote WHERE id = ?", arguments: [id])
                if let text { try db.execute(sql: "INSERT INTO testNote (id, text) VALUES (?, ?)", arguments: [id, text]) }
            }
        }

        func notes() throws -> [String: String] {
            try database.reader.read { db in
                Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT id, text FROM testNote").map { ($0["id"] as String, $0["text"] as String) })
            }
        }

        @discardableResult
        func sync(_ folder: URL) throws -> Bool { try sync.sync(root: folder, device: id) }
    }

    static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    let start = Date(timeIntervalSince1970: 1_795_651_200)

    @Test func editsOnEitherDeviceReachTheOther() throws {
        let a = try Device("aaaa", at: start), b = try Device("bbbb", at: start)
        try a.set("1", "from a")
        try a.sync(folder)
        #expect(try b.sync(folder), "b took a's note")
        #expect(try b.notes() == ["1": "from a"])
        b.clock.now = start.addingTimeInterval(60)
        try b.set("1", "edited on b")
        try b.set("2", "new on b")
        try b.sync(folder)
        a.clock.now = start.addingTimeInterval(120)
        try a.sync(folder)
        #expect(try a.notes() == ["1": "edited on b", "2": "new on b"])
        #expect(try !b.sync(folder), "nothing new: a's applied records aren't edits")
    }

    /// The newest edit wins; at the same moment, the larger device id (so both agree).
    @Test func theNewestEditWinsAndTiesAgree() throws {
        let a = try Device("aaaa", at: start), b = try Device("bbbb", at: start)
        try a.set("1", "a")
        try b.set("1", "b")
        try a.sync(folder)
        try b.sync(folder)
        try a.sync(folder)
        #expect(try a.notes()["1"] == "b" && b.notes()["1"] == "b", "same time: device bbbb")
        a.clock.now = start.addingTimeInterval(10)
        try a.set("1", "a later")
        try a.sync(folder)
        try b.sync(folder)
        #expect(try b.notes()["1"] == "a later")
    }

    /// A deletion is a tombstone: the other device's older copy doesn't bring it back.
    @Test func deletionsStayDeleted() throws {
        let a = try Device("aaaa", at: start), b = try Device("bbbb", at: start)
        try a.set("1", "x")
        try a.sync(folder)
        try b.sync(folder)
        a.clock.now = start.addingTimeInterval(60)
        try a.set("1", nil)
        try a.sync(folder)
        try b.sync(folder)
        #expect(try b.notes().isEmpty)
        try a.sync(folder)
        #expect(try a.notes().isEmpty, "not back from b")
        // After 90 days the tombstone goes, from the database and the file.
        a.clock.now = start.addingTimeInterval(RecordSync.tombstoneLife + 3600)
        try a.sync(folder)
        let count = try a.database.reader.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM syncRecord WHERE collection = 'notes'") }
        #expect(count == 0)
    }

    /// A device whose clock is behind still stamps after the newest edit it has seen, so its
    /// later edit wins.
    @Test func aSlowClockStillStampsAfterWhatItHasSeen() throws {
        let a = try Device("aaaa", at: start), b = try Device("bbbb", at: start.addingTimeInterval(3600))
        try b.set("1", "b, clock an hour ahead")
        try b.sync(folder)
        try a.sync(folder)
        a.clock.now = start.addingTimeInterval(60)
        try a.set("1", "a, a minute later")
        try a.sync(folder)
        try b.sync(folder)
        #expect(try b.notes()["1"] == "a, a minute later")
    }

    /// Daily goals merge by kind and day: each device's days, and the newer edit of the same day.
    @Test func dailyGoalsMergeByDay() throws {
        let a = try Device("aaaa", at: start), b = try Device("bbbb", at: start)
        let storeA = DailyGoalStore(database: a.database), storeB = DailyGoalStore(database: b.database)
        try storeA.set(kind: .reading, measure: .characters, target: 2000, now: start, calendar: Self.utc)
        try a.sync(folder)
        try b.sync(folder)
        let day2 = start.addingTimeInterval(86_400 + 3600)
        b.clock.now = day2
        try storeB.set(kind: .reading, measure: .pages, target: 20, now: day2, calendar: Self.utc)
        try b.sync(folder)
        a.clock.now = day2.addingTimeInterval(60)
        try a.sync(folder)
        let goals = try storeA.goals(kind: .reading, calendar: Self.utc)
        #expect(goals.history.map(\.target) == [2000, 20])
        #expect(goals.goal(on: start)?.measure == .characters && goals.goal(on: day2)?.measure == .pages, "each day its own goal")
        // The same day changed again on a: it replaces b's, on both.
        try storeA.set(kind: .reading, measure: .time, target: 30, now: day2.addingTimeInterval(120), calendar: Self.utc)
        a.clock.now = day2.addingTimeInterval(120)
        try a.sync(folder)
        b.clock.now = day2.addingTimeInterval(180)
        try b.sync(folder)
        let onB = try storeB.goals(kind: .reading, calendar: Self.utc)
        #expect(onB.history.count == 2 && onB.goal(on: day2)?.target == 30)
    }

    /// Another app's files (Miru's, Kiku's) are never read into this one.
    @Test func otherAppsFilesAreIgnored() throws {
        let a = try Device("aaaa", at: start)
        let notes = folder.appending(path: "notes")
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        let other = RecordSyncFile(app: "miru", device: "cccc", records: [.init(id: "1", value: "miru's", editedAt: 1, deleted: false)])
        try JSONEncoder().encode(other).write(to: notes.appending(path: "miru-cccc.json"))
        #expect(try !a.sync(folder))
        #expect(try a.notes().isEmpty)
    }
}
