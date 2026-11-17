import Foundation
import GRDB

/// A word marked known or ignored by hand (the popup's Known and Ignore, Settings ▸ Anki ▸
/// Known Words): Hachidori's `wordStatusOverrides`. It wins over the word's Anki state, and
/// neither is marked in text.
public enum WordStatus: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    case known, ignored
}

/// One headword's mark, in the setup's database (shared by the apps). While a Hachidori host is
/// on, `pendingHost` says the host hasn't been told yet; a cleared mark stays as a row without a
/// status until it has.
public struct WordStatusRecord: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "wordStatus"

    /// The dictionary headword (trimmed, NFC), as Hachidori keys it.
    public var headword: String
    public var status: WordStatus?
    public var updatedAt: Date
    public var pendingHost: Bool

    public init(headword: String, status: WordStatus?, updatedAt: Date = Date(), pendingHost: Bool = false) {
        self.headword = headword
        self.status = status
        self.updatedAt = updatedAt
        self.pendingHost = pendingHost
    }
}

public struct WordStatusStore: Sendable {
    public let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public static func normalized(_ headword: String) -> String {
        headword.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
    }

    /// Every marked headword.
    public func statuses() throws -> [String: WordStatus] {
        try database.reader.read { db in
            var statuses: [String: WordStatus] = [:]
            for record in try WordStatusRecord.filter(Column("status") != nil).fetchAll(db) {
                statuses[record.headword] = record.status
            }
            return statuses
        }
    }

    public func status(of headword: String) throws -> WordStatus? {
        try database.reader.read { try WordStatusRecord.fetchOne($0, key: Self.normalized(headword))?.status }
    }

    /// Marks a headword known or ignored, or clears it (nil). `host`: a Hachidori host is on, so
    /// the change is kept until it's been sent.
    public func set(_ status: WordStatus?, for headword: String, host: Bool, at date: Date = Date()) throws {
        let headword = Self.normalized(headword)
        guard !headword.isEmpty else { return }
        try database.writer.write { db in
            if status == nil, !host {
                _ = try WordStatusRecord.deleteOne(db, key: headword)
            } else {
                try WordStatusRecord(headword: headword, status: status, updatedAt: date, pendingHost: host).save(db)
            }
        }
    }

    /// Settings ▸ Known Words ▸ Add: marks each line's word known. Returns how many were new.
    @discardableResult
    public func addKnown(_ headwords: [String], host: Bool, at date: Date = Date()) throws -> Int {
        let words = headwords.map(Self.normalized).filter { !$0.isEmpty }
        return try database.writer.write { db in
            var added = 0
            for word in Set(words) {
                if try WordStatusRecord.fetchOne(db, key: word)?.status == .known { continue }
                try WordStatusRecord(headword: word, status: .known, updatedAt: date, pendingHost: host).save(db)
                added += 1
            }
            return added
        }
    }

    /// Changes the host hasn't been told about yet.
    public func pendingHost() throws -> [WordStatusRecord] {
        try database.reader.read { try WordStatusRecord.filter(Column("pendingHost") == true).fetchAll($0) }
    }

    /// The host has `record`'s change: it's no longer pending, unless the word changed again
    /// meanwhile. A cleared word's row goes.
    public func sentToHost(_ record: WordStatusRecord) throws {
        try database.writer.write { db in
            guard var current = try WordStatusRecord.fetchOne(db, key: record.headword),
                  current.pendingHost, current.updatedAt == record.updatedAt, current.status == record.status else { return }
            if current.status == nil {
                _ = try current.delete(db)
            } else {
                current.pendingHost = false
                try current.update(db)
            }
        }
    }

    /// Hachidori was turned on: everything marked here goes to it, joining what it has.
    public func sendAllToHost() throws {
        try database.writer.write { db in
            _ = try WordStatusRecord.updateAll(db, Column("pendingHost").set(to: true))
        }
    }

    /// Hachidori was turned off: nothing is waiting for it any more.
    public func forgetHost() throws {
        try database.writer.write { db in
            _ = try WordStatusRecord.filter(Column("status") == nil).deleteAll(db)
            _ = try WordStatusRecord.updateAll(db, Column("pendingHost").set(to: false))
        }
    }

    /// The host's list (`wordStatusOverrides`) becomes ours, except for words changed here that it
    /// hasn't been told about yet. Returns whether anything changed.
    @discardableResult
    public func adoptHost(known: [String], ignored: [String]) throws -> Bool {
        var host: [String: WordStatus] = [:]
        for word in known { host[Self.normalized(word)] = .known }
        for word in ignored { host[Self.normalized(word)] = .ignored }
        return try database.writer.write { db in
            var changed = false
            var local: [String: WordStatusRecord] = [:]
            for record in try WordStatusRecord.fetchAll(db) { local[record.headword] = record }
            for (word, record) in local where !record.pendingHost && host[word] == nil {
                _ = try record.delete(db)
                changed = true
            }
            for (word, status) in host {
                if let record = local[word], record.pendingHost || record.status == status { continue }
                try WordStatusRecord(headword: word, status: status).save(db)
                changed = true
            }
            return changed
        }
    }
}

/// A headword whose mark the Hachidori host should get. The job carries only the word: the
/// handler sends the mark as it is when it's sent (`WordStatusStore`).
public struct WordStatusJob: Codable, Equatable, Sendable {
    public var headword: String

    public init(headword: String) {
        self.headword = headword
    }
}

extension OutboxStore {
    /// Queues telling the host about a word (one job per word).
    public func queueHostWordStatus(_ headword: String) throws {
        let headword = WordStatusStore.normalized(headword)
        try enqueue(WordStatusJob(headword: headword), kind: .hachidoriWordStatus, coalesceKey: "hachidori.status:\(headword)")
    }
}
