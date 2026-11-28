import CryptoKit
import Foundation
import GRDB

/// A synced collection over a settings table: each row is a record, its key column the id and
/// its other columns the value, as sorted JSON. Columns holding JSON (the reader settings) are
/// kept as JSON inside, so the same settings always read the same. `excluded` columns stay on
/// this device (Miru's stream bitrate, Kiku's watch Live Text and hidden libraries): they're
/// left out of the record and untouched when one is applied.
public struct TableCollection: SyncedCollection {
    public let name: String
    let table: String
    let keyColumn: String
    let jsonColumns: Set<String>
    let excluded: Set<String>
    /// When set, only these columns sync (the rest of the row is this device's).
    let only: Set<String>?
    /// The record id for a row's key, or nil to leave the row out (a series of another server).
    let recordID: @Sendable (_ key: String, _ db: Database) throws -> String?
    /// The row key for a record id, or nil to ignore the record on this device.
    let rowKey: @Sendable (_ id: String, _ db: Database) throws -> String?

    public init(name: String, table: String, keyColumn: String, jsonColumns: Set<String> = [], excluded: Set<String> = [],
                only: Set<String>? = nil,
                recordID: @escaping @Sendable (String, Database) throws -> String? = { key, _ in key },
                rowKey: @escaping @Sendable (String, Database) throws -> String? = { id, _ in id }) {
        self.name = name
        self.table = table
        self.keyColumn = keyColumn
        self.jsonColumns = jsonColumns
        self.excluded = excluded
        self.only = only
        self.recordID = recordID
        self.rowKey = rowKey
    }

    public func records(_ db: Database) throws -> [String: Data] {
        var result: [String: Data] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT * FROM \(table.quotedDatabaseIdentifier)") {
            guard let key = Self.text(row[keyColumn]), let id = try recordID(key, db) else { continue }
            var object: [String: Any] = [:]
            for column in row.columnNames where syncs(column) {
                object[column] = try json(row[column] as DatabaseValue, column: column)
            }
            result[id] = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed])
        }
        return result
    }

    public func apply(id: String, value: Data?, _ db: Database) throws {
        guard let key = try rowKey(id, db) else { return }
        let table = table.quotedDatabaseIdentifier, keyColumn = keyColumn.quotedDatabaseIdentifier
        guard let value else {
            try db.execute(sql: "DELETE FROM \(table) WHERE \(keyColumn) = ?", arguments: [key])
            return
        }
        guard let object = try JSONSerialization.jsonObject(with: value) as? [String: Any] else { return }
        let info = try db.columns(in: self.table)
        let known = Set(info.map(\.name))
        // JSON goes back as text into a TEXT column (Kiku's hidden libraries), else as a blob.
        let textColumns = Set(info.filter { $0.type.uppercased() == "TEXT" }.map(\.name))
        var columns: [String] = [], values: [DatabaseValueConvertible?] = []
        for (column, item) in object.sorted(by: { $0.key < $1.key }) where known.contains(column) && syncs(column) {
            columns.append(column)
            values.append(try databaseValue(item, column: column, asText: textColumns.contains(column)))
        }
        // Inserted with the table's defaults for what isn't synced, or updated leaving those be.
        let names = ([self.keyColumn] + columns).map(\.quotedDatabaseIdentifier).joined(separator: ", ")
        let marks = Array(repeating: "?", count: columns.count + 1).joined(separator: ", ")
        let updates = columns.isEmpty ? "NOTHING"
            : "UPDATE SET " + columns.map { "\($0.quotedDatabaseIdentifier) = excluded.\($0.quotedDatabaseIdentifier)" }.joined(separator: ", ")
        try db.execute(sql: "INSERT INTO \(table) (\(names)) VALUES (\(marks)) ON CONFLICT(\(keyColumn)) DO \(columns.isEmpty ? "NOTHING" : updates)",
                       arguments: StatementArguments([key as DatabaseValueConvertible?] + values))
    }

    /// Every synced column empty (NULL, an empty list or text), like an address never set.
    public func isBlank(_ value: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: value) as? [String: Any] else { return false }
        // A row that is only its key (a hidden library) says something by being there.
        return !object.isEmpty && object.values.allSatisfy { item in
            item is NSNull || (item as? [Any])?.isEmpty == true || (item as? String)?.isEmpty == true
        }
    }

    private func syncs(_ column: String) -> Bool {
        column != keyColumn && !excluded.contains(column) && (only?.contains(column) ?? true)
    }

    private static func text(_ value: DatabaseValue) -> String? {
        switch value.storage {
        case .string(let text): text
        case .int64(let number): String(number)
        default: nil
        }
    }

    private func json(_ value: DatabaseValue, column: String) throws -> Any {
        switch value.storage {
        case .null: return NSNull()
        case .int64(let number): return number
        case .double(let number): return number
        case .string(let text):
            if jsonColumns.contains(column), let data = text.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) { return object }
            return text
        case .blob(let data):
            if jsonColumns.contains(column), let object = try? JSONSerialization.jsonObject(with: data) { return object }
            return ["base64": data.base64EncodedString()]
        }
    }

    private func databaseValue(_ item: Any, column: String, asText: Bool) throws -> DatabaseValueConvertible? {
        if item is NSNull { return nil }
        if jsonColumns.contains(column), item is [String: Any] || item is [Any] {
            let data = try JSONSerialization.data(withJSONObject: item, options: [.sortedKeys])
            return asText ? String(decoding: data, as: UTF8.self) : data
        }
        if let object = item as? [String: Any], let base64 = object["base64"] as? String { return Data(base64Encoded: base64) }
        if let number = item as? NSNumber {
            // JSON doesn't tell 1 from 1.0 or true; SQLite's column affinity does the rest.
            return CFNumberIsFloatType(number) ? number.doubleValue : number.int64Value
        }
        return item as? String
    }
}

/// Which Kavita this device reads from, as a short hash of its address: series ids are the
/// server's own, so a series' settings only go to devices on the same server.
public enum SyncServerKey {
    public static func kavita(_ db: Database) throws -> String? { try server(.kavita, db) }

    /// The same for any server: its ids (libraries, items, chapters) are its own.
    public static func server(_ kind: ServerKind, _ db: Database) throws -> String? {
        guard let url = try String.fetchOne(db, sql: "SELECT baseURL FROM serverAccount WHERE kind = ?", arguments: [kind.rawValue]) else { return nil }
        let normal = url.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return SHA256.hash(data: Data(normal.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    /// A record id for a server's own key ("<key>@<server>"), nil without that server.
    static func id(_ key: String, _ kind: ServerKind, _ db: Database) throws -> String? {
        try server(kind, db).map { "\(key)@\($0)" }
    }

    /// The key of a record id, when it's this device's server; nil otherwise.
    static func key(_ id: String, _ kind: ServerKind, _ db: Database) throws -> String? {
        guard let at = id.lastIndex(of: "@"), try server(kind, db) == String(id[id.index(after: at)...]) else { return nil }
        return String(id[..<at])
    }
}

public extension TableCollection {
    /// Yomu's reader settings, manga or book: "global" ("Use for All") as it is, a series'
    /// as "kavita.series.<id>@<server>".
    static func readerSettings(name: String, table: String) -> TableCollection {
        TableCollection(name: name, table: table, keyColumn: "scope", jsonColumns: ["settings"],
                        recordID: { scope, db in
                            guard scope.hasPrefix("kavita.series.") else { return scope }
                            return try SyncServerKey.kavita(db).map { "\(scope)@\($0)" }
                        },
                        rowKey: { id, db in
                            guard let at = id.lastIndex(of: "@") else { return id.hasPrefix("kavita.series.") ? nil : id }
                            return try SyncServerKey.kavita(db) == String(id[id.index(after: at)...]) ? String(id[..<at]) : nil
                        })
    }

    static let mangaReaderSettings = readerSettings(name: "mangaReaderSettings", table: "mangaReaderSettings")
    static let bookReaderSettings = readerSettings(name: "bookReaderSettings", table: "bookReaderSettings")

    /// Miru's player settings, but the stream quality: it depends on the device's connection.
    static let playerSettings = TableCollection(name: "playerSettings", table: "playerSettings", keyColumn: "id", excluded: ["maxStreamBitrate"])

    /// Kiku's playback settings. Hidden libraries go with the server's (later); Live Text on
    /// the watch is this phone's.
    static let listenSettings = TableCollection(name: "listenSettings", table: "listenSettings", keyColumn: "id",
                                                excluded: ["hiddenLibraries", "watchLiveText"])

    /// Kiku's per-show speed and skips, by Audiobookshelf item id.
    static let showListenSettings = TableCollection(name: "showListenSettings", table: "showListenSetting", keyColumn: "itemId")

    /// Kiku's marks and their notes, by their own id: a mark made, mined, noted, cleared or
    /// gone a day after mining is the same everywhere (the last edit of a note wins). The row
    /// number and the card job that mined it are this device's.
    static let audioMarks = TableCollection(name: "audioMarks", table: "audioMark", keyColumn: "uuid", excluded: ["id", "minedJobId"])

    /// A table of one server's ids, every row synced under its server.
    static func serverScoped(name: String, table: String, keyColumn: String, server: ServerKind,
                             jsonColumns: Set<String> = [], only: Set<String>? = nil) -> TableCollection {
        TableCollection(name: name, table: table, keyColumn: keyColumn, jsonColumns: jsonColumns, only: only,
                        recordID: { key, db in try SyncServerKey.id(key, server, db) },
                        rowKey: { id, db in try SyncServerKey.key(id, server, db) })
    }

    /// Yomu's hidden Kavita libraries.
    static let hiddenLibraries = serverScoped(name: "hiddenLibraries", table: "hiddenLibrary", keyColumn: "libraryId", server: .kavita)
    /// Miru's hidden Jellyfin libraries, and those checked for Japanese audio only.
    static let hiddenJellyfinLibraries = serverScoped(name: "hiddenJellyfinLibraries", table: "hiddenJellyfinLibrary",
                                                      keyColumn: "libraryId", server: .jellyfin)
    static let japaneseOnlyJellyfinLibraries = serverScoped(name: "japaneseOnlyJellyfinLibraries", table: "japaneseOnlyJellyfinLibrary",
                                                            keyColumn: "libraryId", server: .jellyfin)
    /// Kiku's hidden Audiobookshelf libraries: that one column of its playback settings.
    static let kikuHiddenLibraries = serverScoped(name: "kikuHiddenLibraries", table: "listenSettings", keyColumn: "id",
                                                  server: .audiobookshelf, jsonColumns: ["hiddenLibraries"], only: ["hiddenLibraries"])
    /// The kechimochi address in Settings ▸ Stats (each app its own).
    static let kechimochiAddress = TableCollection(name: "kechimochiAddress", table: "statsState", keyColumn: "id", only: ["kechimochiURL"])

    /// The lookup popup's settings, in the shared setup (synced only while it's shared and no
    /// Hachidori is linked).
    static let popupSettings = TableCollection(name: "popupSettings", table: "popupSettings", keyColumn: "id")
}
