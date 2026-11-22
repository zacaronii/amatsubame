import CryptoKit
import Foundation
import GRDB

/// One device's activity for one month, as it's kept in the sync folder (iCloud): a device only
/// ever writes its own files and reads the others', so two devices never edit the same file.
public struct StatsSyncFile: Codable, Equatable, Sendable {
    public struct Session: Codable, Equatable, Sendable {
        public var kind: ActivitySession.Kind
        public var seriesKey: String
        public var seriesTitle: String
        public var itemKey: String
        /// Seconds since 1970.
        public var start: Double
        public var end: Double
        public var characters: Int
        public var pages: Int
        public var seconds: Double
    }

    public var version = 1
    public var device: String
    /// "2026-11" (UTC), by the sessions' starts.
    public var month: String
    public var sessions: [Session]
    /// Lookups, in whole seconds since 1970.
    public var lookups: [Int]

    static func name(device: String, month: String) -> String { "\(device)_\(month).json" }

    /// The device and month in a file's name; nil for anything else in the folder.
    static func parse(name: String) -> (device: String, month: String)? {
        guard name.hasSuffix(".json") else { return nil }
        let parts = name.dropLast(5).split(separator: "_")
        guard parts.count == 2, parts[1].count == 7 else { return nil }
        return (String(parts[0]), String(parts[1]))
    }

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    static func month(of date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
    }

    /// The month's first moment and the next month's.
    static func range(of month: String) -> (start: Date, end: Date)? {
        let parts = month.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2, let start = calendar.date(from: DateComponents(year: parts[0], month: parts[1])),
              let end = calendar.date(byAdding: .month, value: 1, to: start) else { return nil }
        return (start, end)
    }
}

/// The folder the files are in: the app's iCloud container on a device, any folder in tests.
/// Files another device changed arrive as placeholders first; those are asked for and read on a
/// later pass.
public struct StatsSyncFolder: Sendable {
    public struct Entry: Equatable, Sendable {
        public var name: String
        /// Changes when the file does.
        public var token: String
        /// False while iCloud still has to bring the file (or its newer version) down.
        public var isCurrent: Bool
    }

    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func entries() throws -> [Entry] {
        let files = FileManager.default
        try files.createDirectory(at: url, withIntermediateDirectories: true)
        // Asks iCloud to look for news in the folder (nothing happens anywhere else).
        try? files.startDownloadingUbiquitousItem(at: url)
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .ubiquitousItemDownloadingStatusKey]
        return try files.contentsOfDirectory(at: url, includingPropertiesForKeys: Array(keys), options: []).compactMap { file in
            var name = file.lastPathComponent
            // An undownloaded file used to be listed as ".name.icloud".
            if name.hasPrefix("."), name.hasSuffix(".icloud") {
                name = String(name.dropFirst().dropLast(7))
                try? files.startDownloadingUbiquitousItem(at: url.appending(path: name))
                return Entry(name: name, token: "", isCurrent: false)
            }
            guard !name.hasPrefix(".") else { return nil }
            let values = try? file.resourceValues(forKeys: keys)
            let status = values?.ubiquitousItemDownloadingStatus
            let isCurrent = status == nil || status == .current
            if !isCurrent { try? files.startDownloadingUbiquitousItem(at: file) }
            let modified = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
            return Entry(name: name, token: String(format: "%.3f", modified), isCurrent: isCurrent)
        }
    }

    public func read(_ name: String) throws -> Data {
        var result: Result<Data, Error> = .failure(CocoaError(.fileReadUnknown))
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url.appending(path: name), options: [], error: &coordinationError) { file in
            result = Result { try Data(contentsOf: file) }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }

    public func write(_ data: Data, to name: String) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var result: Result<Void, Error> = .success(())
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url.appending(path: name), options: .forReplacing, error: &coordinationError) { file in
            result = Result { try data.write(to: file, options: .atomic) }
        }
        if let coordinationError { throw coordinationError }
        try result.get()
    }
}

/// Keeps Stats the same on every device with the same iCloud account: this device's activity
/// goes out as one file a month, and the other devices' files come in as rows marked with their
/// device, which Stats counts along with this device's own.
public struct StatsSync: Sendable {
    public let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    /// This install's name in the folder. `hardware` tells devices apart when the database was
    /// copied to another one (a restored backup, Migration Assistant): what was logged so far
    /// then stays with the device it came from, and this one starts under a new name, so the two
    /// don't overwrite each other's files or count the same reading twice.
    public func deviceID(hardware: String? = nil) throws -> String {
        try database.writer.write { db in
            let row = try Row.fetchOne(db, sql: "SELECT deviceId, deviceHardware FROM statsState WHERE id = 1")
            let saved: String? = row?["deviceId"]
            let savedHardware: String? = row?["deviceHardware"]
            if let saved, hardware == nil || savedHardware == nil || savedHardware == hardware {
                if savedHardware == nil, let hardware {
                    try db.execute(sql: "UPDATE statsState SET deviceHardware = ? WHERE id = 1", arguments: [hardware])
                }
                return saved
            }
            if let saved {
                try db.execute(sql: "UPDATE activitySession SET device = ? WHERE device IS NULL", arguments: [saved])
                try db.execute(sql: "UPDATE lookupEvent SET device = ? WHERE device IS NULL", arguments: [saved])
                try db.execute(sql: "DELETE FROM statsSyncFile")
            }
            let id = UUID().uuidString.lowercased()
            try db.execute(sql: """
                INSERT INTO statsState (id, deviceId, deviceHardware) VALUES (1, ?, ?)
                ON CONFLICT(id) DO UPDATE SET deviceId = excluded.deviceId, deviceHardware = excluded.deviceHardware
                """, arguments: [id, hardware])
            return id
        }
    }

    /// Sends what's new here and takes in what's new from the other devices. True when Stats
    /// has something new to show.
    @discardableResult
    public func sync(with folder: StatsSyncFolder, hardware: String? = nil) throws -> Bool {
        let device = try deviceID(hardware: hardware)
        let entries = try folder.entries()
        try export(device: device, to: folder, entries: entries)
        return try importOthers(device: device, from: folder, entries: entries) > 0
    }

    /// Writes this device's months whose contents changed (or whose file is gone). Returns how many.
    @discardableResult
    func export(device: String, to folder: StatsSyncFolder, entries: [StatsSyncFolder.Entry]) throws -> Int {
        let (sessions, lookups, tokens) = try database.reader.read { db in
            (try ActivitySession.filter(Column("device") == nil).order(Column("start"), Column("id")).fetchAll(db),
             try Date.fetchAll(db, sql: "SELECT createdAt FROM lookupEvent WHERE device IS NULL ORDER BY createdAt"),
             try tokens(db))
        }
        var files: [String: StatsSyncFile] = [:]
        func file(_ month: String, _ change: (inout StatsSyncFile) -> Void) {
            change(&files[month, default: StatsSyncFile(device: device, month: month, sessions: [], lookups: [])])
        }
        for session in sessions {
            file(StatsSyncFile.month(of: session.start)) {
                $0.sessions.append(.init(kind: session.kind, seriesKey: session.seriesKey, seriesTitle: session.seriesTitle,
                                         itemKey: session.itemKey, start: Self.seconds(session.start), end: Self.seconds(session.end),
                                         characters: session.characters, pages: session.pages, seconds: session.seconds))
            }
        }
        for lookup in lookups {
            file(StatsSyncFile.month(of: lookup)) { $0.lookups.append(Int(lookup.timeIntervalSince1970)) }
        }
        // A month sent before that's empty now (its activity was removed) is sent empty.
        for name in tokens.keys {
            if let parsed = StatsSyncFile.parse(name: name), parsed.device == device { file(parsed.month) { _ in } }
        }
        let present = Set(entries.map(\.name))
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        var written = 0
        for (month, file) in files.sorted(by: { $0.key < $1.key }) {
            let name = StatsSyncFile.name(device: device, month: month)
            let data = try encoder.encode(file)
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            if tokens[name] == hash, present.contains(name) { continue }
            try folder.write(data, to: name)
            try saveToken(hash, for: name)
            written += 1
        }
        return written
    }

    /// Takes in the other devices' files that changed since they were last read. Returns how many.
    @discardableResult
    func importOthers(device: String, from folder: StatsSyncFolder, entries: [StatsSyncFolder.Entry]) throws -> Int {
        let tokens = try database.reader.read { try tokens($0) }
        var imported = 0
        for entry in entries where entry.isCurrent && tokens[entry.name] != entry.token {
            guard let parsed = StatsSyncFile.parse(name: entry.name), parsed.device != device,
                  let range = StatsSyncFile.range(of: parsed.month),
                  let file = try? JSONDecoder().decode(StatsSyncFile.self, from: folder.read(entry.name)),
                  file.device == parsed.device, file.month == parsed.month else { continue }
            try database.writer.write { db in
                try db.execute(sql: "DELETE FROM activitySession WHERE device = ? AND start >= ? AND start < ?",
                               arguments: [file.device, range.start, range.end])
                try db.execute(sql: "DELETE FROM lookupEvent WHERE device = ? AND createdAt >= ? AND createdAt < ?",
                               arguments: [file.device, range.start, range.end])
                for session in file.sessions {
                    var row = ActivitySession(kind: session.kind, seriesKey: session.seriesKey, seriesTitle: session.seriesTitle,
                                              itemKey: session.itemKey, start: Date(timeIntervalSince1970: session.start),
                                              end: Date(timeIntervalSince1970: session.end), characters: session.characters,
                                              pages: session.pages, seconds: session.seconds, device: file.device)
                    // A session is filed under the month it started in, whatever the file says.
                    guard row.start >= range.start, row.start < range.end else { continue }
                    try row.insert(db)
                }
                for lookup in file.lookups {
                    let date = Date(timeIntervalSince1970: Double(lookup))
                    guard date >= range.start, date < range.end else { continue }
                    try db.execute(sql: "INSERT INTO lookupEvent (createdAt, device) VALUES (?, ?)", arguments: [date, file.device])
                }
                try db.execute(sql: """
                    INSERT INTO statsSyncFile (name, token) VALUES (?, ?)
                    ON CONFLICT(name) DO UPDATE SET token = excluded.token
                    """, arguments: [entry.name, entry.token])
            }
            imported += 1
        }
        return imported
    }

    private func tokens(_ db: Database) throws -> [String: String] {
        var result: [String: String] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT name, token FROM statsSyncFile") {
            result[row["name"]] = row["token"]
        }
        return result
    }

    private func saveToken(_ token: String, for name: String) throws {
        try database.writer.write { db in
            try db.execute(sql: """
                INSERT INTO statsSyncFile (name, token) VALUES (?, ?)
                ON CONFLICT(name) DO UPDATE SET token = excluded.token
                """, arguments: [name, token])
        }
    }

    /// To the millisecond, which is what the database keeps.
    private static func seconds(_ date: Date) -> Double {
        (date.timeIntervalSince1970 * 1000).rounded() / 1000
    }
}
