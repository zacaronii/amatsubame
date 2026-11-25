import Foundation
import GRDB

/// Yomu's read-along pairings with Sync with iCloud: which audiobook goes with which EPUB
/// volume, per Kavita server. Only the choice: each device aligns the two again itself (the
/// alignment is large and quick to redo), and a pairing moved to another audiobook drops
/// the alignment made for the old one.
public struct ReadAlongPairCollection: SyncedCollection {
    public let name = "readAlongPairs"

    public init() {}

    struct Value: Codable {
        var itemId: String
        var bookTitle: String
        var createdAt: Double
        var readsAlong: Bool
    }

    public func records(_ db: Database) throws -> [String: Data] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        var result: [String: Data] = [:]
        for pair in try ReadAlongPair.fetchAll(db) {
            guard let id = try SyncServerKey.id(String(pair.chapterId), .kavita, db) else { continue }
            result[id] = try encoder.encode(Value(itemId: pair.itemId, bookTitle: pair.bookTitle,
                                                  createdAt: pair.createdAt.timeIntervalSince1970.rounded(), readsAlong: pair.readsAlong))
        }
        return result
    }

    public func apply(id: String, value: Data?, _ db: Database) throws {
        guard let key = try SyncServerKey.key(id, .kavita, db), let chapterId = Int(key) else { return }
        guard let value else {
            _ = try ReadAlongPair.deleteOne(db, key: chapterId)
            return
        }
        guard let new = try? JSONDecoder().decode(Value.self, from: value) else { return }
        var pair = try ReadAlongPair.fetchOne(db, key: chapterId)
            ?? ReadAlongPair(chapterId: chapterId, itemId: new.itemId, bookTitle: new.bookTitle,
                             createdAt: Date(timeIntervalSince1970: new.createdAt))
        if pair.itemId != new.itemId {
            // Another audiobook: what was aligned for the old one doesn't hold.
            pair.itemId = new.itemId
            pair.alignedAt = nil
            pair.transcriptFingerprint = nil
            pair.alignmentVersion = nil
            pair.cues = nil
            pair.matchedSentences = nil
            pair.totalSentences = nil
            pair.transcriptModel = nil
            pair.transcriptKaku = nil
            pair.transcribedAt = nil
        }
        pair.bookTitle = new.bookTitle
        pair.createdAt = Date(timeIntervalSince1970: new.createdAt)
        pair.readsAlong = new.readsAlong
        try pair.save(db)
    }
}

/// Miru's timing fix for a Jimaku subtitle with Sync with iCloud, per Jellyfin item: the file
/// chosen and its offset. It's applied only where the same file is there (the subtitle itself
/// comes through Jellyfin once uploaded, or is downloaded again); a subtitle is never removed
/// by another device.
public struct SubtitleTimingCollection: SyncedCollection {
    public let name = "subtitleTimings"

    public init() {}

    struct Value: Codable {
        var source: String
        var fileName: String
        var offset: Double
    }

    public func records(_ db: Database) throws -> [String: Data] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        var result: [String: Data] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT itemId, source, fileName, offset FROM localSubtitle") {
            guard let id = try SyncServerKey.id(row["itemId"], .jellyfin, db) else { continue }
            result[id] = try encoder.encode(Value(source: row["source"], fileName: row["fileName"], offset: row["offset"]))
        }
        return result
    }

    public func apply(id: String, value: Data?, _ db: Database) throws {
        guard let itemId = try SyncServerKey.key(id, .jellyfin, db), let value,
              let new = try? JSONDecoder().decode(Value.self, from: value) else { return }
        try db.execute(sql: "UPDATE localSubtitle SET offset = ? WHERE itemId = ? AND source = ? AND fileName = ?",
                       arguments: [new.offset, itemId, new.source, new.fileName])
    }
}
