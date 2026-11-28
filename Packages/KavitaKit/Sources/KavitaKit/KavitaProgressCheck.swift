import Core
import Foundation

/// Whether a progress change for a chapter (a page turn, or a mark) still goes to Kavita, as
/// `KavitaProgressHandler` decides it, shared with the readers' start so where a reader opens
/// never contradicts what will be sent.
public enum KavitaProgressCheck {
    /// A change made at `madeAt` still goes if Kavita's progress for the chapter didn't change
    /// after it, or if what Kavita holds is this device's own last send (its previous change,
    /// still on its way when this one was made).
    public static func stillGoes(madeAt: Date, server: KavitaServerProgress, chapterId: Int, seriesId: Int,
                                 outbox: OutboxStore?, excluding job: Int64?) throws -> Bool {
        guard let changed = server.lastModifiedUtc, changed > madeAt else { return true }
        return try holdsOwnLastSend(server, chapterId: chapterId, seriesId: seriesId, outbox: outbox, excluding: job)
    }

    /// At a reader's start: whether a change for the chapter (or its series) still queued here
    /// will be sent, by `stillGoes` for each such job. Only then does this device's place win
    /// over Kavita's newer one; a change the handler will drop doesn't hold it.
    public static func queuedChangeStillGoes(chapterId: Int, seriesId: Int, server: KavitaServerProgress, outbox: OutboxStore) throws -> Bool {
        for job in try outbox.unsentProgressJobs(coalesceKeys: LocalReadingProgress.progressKeys(chapterId: chapterId, seriesId: seriesId)) {
            let madeAt = (try? job.decodePayload(KavitaReadMarkPayload.self))?.madeAt
                ?? (try? job.decodePayload(KavitaProgressPayload.self))?.madeAt ?? job.updatedAt
            if try stillGoes(madeAt: madeAt, server: server, chapterId: chapterId, seriesId: seriesId, outbox: outbox, excluding: job.id) {
                return true
            }
        }
        return false
    }

    /// Whether Kavita's progress for the chapter is what this device last sent for it: the last
    /// sent page turn or mark of the chapter, or mark of its series, whichever went last. Kavita
    /// gives back exactly what was sent (pageNum and bookScrollId, checked live 2026-11-23); a
    /// read mark leaves the chapter's pages as pages read (the book's place kept), an unread
    /// one none. A mark without its pages (from an older build) never counts. "Sent" includes
    /// a job skipped for newer reading elsewhere, which never reached Kavita: harmless, as it
    /// only counts if Kavita happens to hold that same place.
    static func holdsOwnLastSend(_ server: KavitaServerProgress, chapterId: Int, seriesId: Int, outbox: OutboxStore?, excluding job: Int64?) throws -> Bool {
        guard let outbox, let last = try outbox.lastSent(coalesceKeys: LocalReadingProgress.progressKeys(chapterId: chapterId, seriesId: seriesId),
                                                          kind: .kavitaProgress, excluding: job) else { return false }
        if let mark = try? last.decodePayload(KavitaReadMarkPayload.self) {
            guard mark.chapterId == nil || mark.chapterId == chapterId else { return false }
            if mark.mark == .unread { return server.pageNum == 0 }
            return mark.chapterPages?[chapterId].map { $0 == server.pageNum } ?? false
        }
        if let turn = try? last.decodePayload(KavitaProgressPayload.self) {
            return turn.chapterId == chapterId && turn.pageNum == server.pageNum && turn.bookScrollId == server.bookScrollId
        }
        return false
    }
}
