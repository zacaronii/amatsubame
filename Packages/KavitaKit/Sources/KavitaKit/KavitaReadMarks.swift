import Core
import Foundation
import GRDB

// Verified against Kavita 0.9.1 (2026-11-23) with a test account, and in the source at the
// v0.7.8–v0.8.8 tags: `POST /api/Reader/mark-multiple-read` / `mark-multiple-unread`
// {seriesId, volumeIds, chapterIds} (chapterIds alone works) and `mark-read` / `mark-unread`
// {seriesId} are all in 0.7.8. They add nothing to Kavita's reading sessions (only when
// `generateReadingSession` is true, which Yomu never sends), unlike `Reader/progress`, which has
// fed them since 0.8.9: marking through it showed as pages read in Kavita's reading history.
// Unread sets pagesRead to 0 and keeps a book's bookScrollId.

/// Mark as Read / Unread, queued in the progress lane (`kavitaProgress`) so it's sent in order
/// with page turns: a chapter's mark shares that chapter's coalesce key (the latest of the two
/// is what's sent), a series' mark is one job that replaces the series' queued page turns.
public struct KavitaReadMarkPayload: Codable, Equatable, Sendable {
    public enum Mark: String, Codable, Sendable { case read, unread }
    public var mark: Mark
    public var seriesId: Int
    /// One chapter; nil marks the whole series.
    public var chapterId: Int?
    /// The account it was made under (`ReaderMarkStore.accountKey`): another one waits.
    public var account: String?
    /// When it was made (the progress rows' time): judged against Kavita by this, not by when
    /// the job is sent, so a mark sent days later never undoes reading done elsewhere meanwhile.
    public var madeAt: Date
    /// The pages of each chapter it marks (what a read mark leaves as pages read on Kavita), so
    /// a later change can tell Kavita holding this mark from reading elsewhere. Marks queued
    /// before it existed have none.
    public var chapterPages: [Int: Int]?

    public init(mark: Mark, seriesId: Int, chapterId: Int?, account: String?, madeAt: Date, chapterPages: [Int: Int]? = nil) {
        self.mark = mark
        self.seriesId = seriesId
        self.chapterId = chapterId
        self.account = account
        self.madeAt = madeAt
        self.chapterPages = chapterPages
    }

    public var coalesceKey: String { chapterId.map { "kavita.chapter.\($0)" } ?? "kavita.series.\(seriesId)" }
}

extension KavitaClient {
    // Writes: call only from the outbox handler.

    public func markRead(_ read: Bool, seriesId: Int, chapterIds: [Int]) async throws(ConnectionError) {
        _ = try await http.send(jsonRequest("POST", read ? "api/Reader/mark-multiple-read" : "api/Reader/mark-multiple-unread",
                                            body: MarkMultiple(seriesId: seriesId, volumeIds: [], chapterIds: chapterIds)))
    }

    public func markSeriesRead(_ read: Bool, seriesId: Int) async throws(ConnectionError) {
        _ = try await http.send(jsonRequest("POST", read ? "api/Reader/mark-read" : "api/Reader/mark-unread", body: ["seriesId": seriesId]))
    }

    private struct MarkMultiple: Encodable {
        var seriesId: Int
        var volumeIds: [Int]
        var chapterIds: [Int]
    }
}

/// After an unread mark reached Kavita, this device's rows it wrote are moved just past Kavita's
/// date for the chapter, so the device's page 0 (no place in the book) stays the newer one:
/// Kavita keeps a book's old `bookScrollId` on unread, and its newer row would otherwise bring
/// that place back here. A row changed since the mark (a page turned) is left alone.
public struct KavitaReadMarkSettling: Sendable {
    let progress: ReadingProgressStore

    public init(progress: ReadingProgressStore) {
        self.progress = progress
    }

    func settle(_ mark: KavitaReadMarkPayload, kavitaDates: [Int: Date]) throws {
        try progress.database.writer.write { db in
            for (chapterId, date) in kavitaDates {
                guard var row = try LocalReadingProgress.fetchOne(db, key: chapterId), row.page == 0,
                      abs(row.updatedAt.timeIntervalSince(mark.madeAt)) < 0.01, date >= row.updatedAt else { continue }
                row.updatedAt = date.addingTimeInterval(1)
                try row.save(db)
            }
        }
    }
}

/// Marks chapters or a whole series read or unread on this device and queues them for Kavita,
/// each chapter's progress row and its job in one write. Nothing is recorded as reading (no
/// activity, characters or streak): only the progress rows and the outbox change.
public struct KavitaReadMarking: Sendable {
    let database: AppDatabase
    let outbox: OutboxStore

    public init(database: AppDatabase, outbox: OutboxStore) {
        self.database = database
        self.outbox = outbox
    }

    public struct Chapter: Sendable {
        public var chapterId, volumeId, pages: Int
        public init(chapterId: Int, volumeId: Int, pages: Int) {
            self.chapterId = chapterId
            self.volumeId = volumeId
            self.pages = pages
        }
    }

    /// Chapters (a volume's, or one): one job per chapter, replacing its queued page turn.
    public func mark(_ read: Bool, _ chapters: [Chapter], seriesId: Int, libraryId: Int, account: String?) throws {
        let now = outbox.now()
        try database.writer.write { db in
            for chapter in chapters {
                try Self.progress(chapter, read, seriesId: seriesId, libraryId: libraryId, now: now).save(db)
                let payload = KavitaReadMarkPayload(mark: read ? .read : .unread, seriesId: seriesId, chapterId: chapter.chapterId, account: account,
                                                    madeAt: now, chapterPages: [chapter.chapterId: chapter.pages])
                try outbox.enqueue(payload, kind: .kavitaProgress, coalesceKey: payload.coalesceKey, in: db)
            }
        }
    }

    /// The whole series (every chapter given): one job; the series' queued page turns and
    /// chapter marks are replaced by it.
    public func markSeries(_ read: Bool, _ chapters: [Chapter], seriesId: Int, libraryId: Int, account: String?) throws {
        let now = outbox.now()
        try database.writer.write { db in
            try OutboxStore.cancel(db, coalesceKeys: chapters.map { "kavita.chapter.\($0.chapterId)" })
            for chapter in chapters {
                try Self.progress(chapter, read, seriesId: seriesId, libraryId: libraryId, now: now).save(db)
            }
            let payload = KavitaReadMarkPayload(mark: read ? .read : .unread, seriesId: seriesId, chapterId: nil, account: account, madeAt: now,
                                                chapterPages: Dictionary(chapters.map { ($0.chapterId, $0.pages) }, uniquingKeysWith: max))
            try outbox.enqueue(payload, kind: .kavitaProgress, coalesceKey: payload.coalesceKey, in: db)
        }
    }

    static func progress(_ chapter: Chapter, _ read: Bool, seriesId: Int, libraryId: Int, now: Date) -> LocalReadingProgress {
        LocalReadingProgress(chapterId: chapter.chapterId, seriesId: seriesId, volumeId: chapter.volumeId, libraryId: libraryId,
                             page: read ? max(chapter.pages - 1, 0) : 0, pages: chapter.pages, updatedAt: now)
    }
}
