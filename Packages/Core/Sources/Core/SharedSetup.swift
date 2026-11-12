import Foundation
import GRDB
import notify
#if os(macOS)
import Security
#endif

/// The setup the apps can share through the App Group (needs the paid developer membership):
/// dictionaries (files and list), audio sources, the AnkiConnect account and settings, and
/// mined-word marks. Each app either uses it ("Share setup with my other apps", the default)
/// or keeps its own. Servers, progress, downloads, the outbox and history stay per app.
public struct SharedSetup: Sendable {
    public static let groupIdentifier = "group.com.amatsubame"
    /// Darwin notification posted after any change to the shared setup.
    public static let changedNotification = "com.amatsubame.setupChanged"

    /// Tables that make up a setup (the AnkiConnect row of `serverAccount` too).
    /// After the tables they refer to (rows are inserted in this order).
    public static let tables = ["dictionary", "dictionarySource", "dictionarySettings", "audioSource", "ankiSettings", "minedWord"]
    public static let sharedServerKinds: Set<ServerKind> = [.anki]
    /// Changes other running apps must reload for (the rest is read fresh on each use).
    public static let reloadTables = ["dictionary", "dictionarySettings"]
    /// The shared Keychain items (the AnkiConnect key), in the App Group's access group.
    public static let keychainService = "com.amatsubame.shared"

    public let root: URL
    public var databaseDirectory: URL { root.appending(path: "Database", directoryHint: .isDirectory) }
    public var dictionaryDirectory: URL { root.appending(path: "Dictionaries", directoryHint: .isDirectory) }

    public init(root: URL) {
        self.root = root
    }

    /// The shared setup's folder in the App Group, when this process is entitled to it.
    public static func inAppGroup(
        containerURL: (String) -> URL? = { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) }
    ) -> SharedSetup? {
        #if os(macOS)
        // Without the entitlement, touching a group folder can make macOS ask the user for access.
        guard hasGroupEntitlement() else { return nil }
        #endif
        guard let group = containerURL(groupIdentifier) else { return nil }
        let root = group.appending(path: "Library/Application Support/Shared Setup", directoryHint: .isDirectory)
        // macOS may return a folder without the entitlement; it then can't be created.
        guard (try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)) != nil else { return nil }
        return SharedSetup(root: root)
    }

    #if os(macOS)
    static func hasGroupEntitlement() -> Bool {
        guard let task = SecTaskCreateFromSelf(nil),
              let groups = SecTaskCopyValueForEntitlement(task, "com.apple.security.application-groups" as CFString, nil) as? [String]
        else { return false }
        return groups.contains(groupIdentifier)
    }
    #endif

    public func openDatabase() throws -> AppDatabase {
        try AppDatabase.onDisk(directory: databaseDirectory, shared: true)
    }

    // MARK: Where it came from

    /// Which app set the shared setup up, and when: setup's "Use your existing setup?" step.
    public struct Origin: Codable, Equatable, Sendable {
        public var app: String
        public var date: Date

        public init(app: String, date: Date = Date()) {
            self.app = app
            self.date = date
        }
    }

    var originFile: URL { root.appending(path: "origin.json") }

    /// Nil for setups made before this was recorded.
    public var origin: Origin? {
        (try? Data(contentsOf: originFile)).flatMap { try? JSONDecoder().decode(Origin.self, from: $0) }
    }

    /// Records the app that filled the setup in, unless one already did.
    public func noteOrigin(app: String) {
        guard origin == nil, let data = try? JSONEncoder().encode(Origin(app: app)) else { return }
        try? data.write(to: originFile)
    }

    // MARK: Who shares it

    var membersFile: URL { root.appending(path: "members.json") }

    /// Each app that has opened with the App Group, and whether it uses the shared setup
    /// (an app that chose its own setup is recorded as not sharing).
    public var members: [String: Bool] {
        (try? Data(contentsOf: membersFile)).flatMap { try? JSONDecoder().decode([String: Bool].self, from: $0) } ?? [:]
    }

    public func noteMember(app: String, sharing: Bool) {
        var members = members
        guard members[app] != sharing else { return }
        members[app] = sharing
        try? JSONEncoder().encode(members).write(to: membersFile)
    }

    // MARK: Copying a setup

    /// Nothing set up yet: no dictionaries and no AnkiConnect account.
    public static func isEmpty(_ database: AppDatabase) throws -> Bool {
        try database.reader.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM dictionary")! == 0
                && Int.fetchOne(db, sql: "SELECT COUNT(*) FROM serverAccount WHERE kind = ?", arguments: [ServerKind.anki.rawValue])! == 0
        }
    }

    /// Replaces the destination's setup with the source's: the rows of `tables`, the
    /// AnkiConnect account, and the dictionary folders (`folder`, or the id).
    public static func copy(from source: (database: AppDatabase, dictionaries: URL),
                            to destination: (database: AppDatabase, dictionaries: URL)) throws {
        var rows: [String: [Row]] = [:]
        try source.database.reader.read { db in
            for table in tables { rows[table] = try Row.fetchAll(db, sql: "SELECT * FROM \(table)") }
            rows["serverAccount"] = try Row.fetchAll(db, sql: "SELECT * FROM serverAccount WHERE kind = ?",
                                                     arguments: [ServerKind.anki.rawValue])
        }
        let ids = Set((rows["dictionary"] ?? []).compactMap { row in (row["folder"] as String?) ?? (row["id"] as String?) })
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination.dictionaries, withIntermediateDirectories: true)
        for id in ids {
            let from = source.dictionaries.appending(path: id, directoryHint: .isDirectory)
            let to = destination.dictionaries.appending(path: id, directoryHint: .isDirectory)
            guard fileManager.fileExists(atPath: from.path(percentEncoded: false)) else { continue }
            if fileManager.fileExists(atPath: to.path(percentEncoded: false)) { try fileManager.removeItem(at: to) }
            try fileManager.copyItem(at: from, to: to)
        }
        try destination.database.writer.write { db in
            for table in tables + ["serverAccount"] {
                if table == "serverAccount" {
                    try db.execute(sql: "DELETE FROM serverAccount WHERE kind = ?", arguments: [ServerKind.anki.rawValue])
                } else {
                    try db.execute(sql: "DELETE FROM \(table)")
                }
                for row in rows[table] ?? [] {
                    let columns = Array(row.columnNames)
                    let sql = "INSERT INTO \(table) (\(columns.map { "\"\($0)\"" }.joined(separator: ", "))) VALUES (\(columns.map { _ in "?" }.joined(separator: ", ")))"
                    try db.execute(sql: sql, arguments: StatementArguments(columns.map { row[$0] as DatabaseValue }))
                }
            }
        }
        // Folders of dictionaries the destination no longer lists.
        let present = (try? fileManager.contentsOfDirectory(atPath: destination.dictionaries.path(percentEncoded: false))) ?? []
        for name in present where !ids.contains(name) && !name.hasPrefix(".") {
            try? fileManager.removeItem(at: destination.dictionaries.appending(path: name))
        }
    }

    // MARK: Changes between processes

    public static func postChanged() {
        notify_post(changedNotification)
    }

    /// Calls `handler` (on `queue`) when any process changes the shared setup.
    public static func observeChanges(queue: DispatchQueue = .main, _ handler: @escaping @Sendable () -> Void) -> ChangeObservation {
        var token: Int32 = 0
        notify_register_dispatch(changedNotification, &token, queue) { _ in handler() }
        return ChangeObservation(token: token)
    }

    public final class ChangeObservation: Sendable {
        let token: Int32
        init(token: Int32) { self.token = token }
        deinit { notify_cancel(token) }
    }
}
