import Core
import Foundation

/// Delivers queued reading progress to Kavita.
public struct KavitaProgressHandler: OutboxHandler {
    public let kind = OutboxJobKind.kavitaProgress
    /// Built per send so changes in Settings take effect; nil when Kavita isn't set up.
    let makeClient: @Sendable () throws -> KavitaClient?
    /// The signed-in account (`ReaderMarkStore.accountKey`): a mark made under another waits.
    let account: @Sendable () -> String?
    /// False in UI tests that send marks but hold reading progress: page turns wait.
    let sendsPageTurns: Bool
    /// This device's progress, kept the newer after an unread mark (nil: left as it is).
    let settling: KavitaReadMarkSettling?
    /// The outbox, for what this device last sent for a chapter (sent jobs are kept 7 days).
    let outbox: OutboxStore?

    public init(account: @escaping @Sendable () -> String? = { nil }, sendsPageTurns: Bool = true, progress: ReadingProgressStore? = nil,
                outbox: OutboxStore? = nil, makeClient: @escaping @Sendable () throws -> KavitaClient?) {
        self.account = account
        self.sendsPageTurns = sendsPageTurns
        settling = progress.map(KavitaReadMarkSettling.init)
        self.outbox = outbox
        self.makeClient = makeClient
    }

    public func send(_ job: OutboxJob, media: [(field: String, url: URL)]) async throws {
        if let mark = try? job.decodePayload(KavitaReadMarkPayload.self) {
            try await send(mark, job)
            return
        }
        guard sendsPageTurns else { throw OutboxWait("Reading progress is held.", retryAfter: 3600) }
        let payload: KavitaProgressPayload
        do {
            payload = try job.decodePayload(KavitaProgressPayload.self)
        } catch {
            throw OutboxPermanentFailure("Unreadable progress job: \(error.localizedDescription)")
        }
        guard let client = try makeClient() else {
            throw ConnectionError.message("Kavita isn't set up.")
        }
        do {
            // Newer wins, judged by when the page was turned (`madeAt`; jobs queued before it
            // existed: when sent): if Kavita moved on after that (read elsewhere meanwhile), this
            // older page isn't sent. Kavita's newer date can also be this device's own previous
            // turn of the chapter, still on its way when this one was made: that's recognised by
            // Kavita holding exactly what this device last sent, and doesn't count.
            let server = try await client.progress(chapterId: payload.chapterId)
            guard try KavitaProgressCheck.stillGoes(madeAt: payload.madeAt ?? job.updatedAt, server: server, chapterId: payload.chapterId,
                                                    seriesId: payload.seriesId, outbox: outbox, excluding: job.id) else { return }
            try await client.saveProgress(payload)
        } catch let error as ConnectionError {
            if case .server(let status) = error, (400..<500).contains(status), status != 408, status != 429 {
                throw OutboxPermanentFailure("Kavita rejected the progress update (HTTP \(status)).")
            }
            throw error
        }
    }

    /// A mark, through Kavita's mark endpoints (never `Reader/progress`, which would record it
    /// as reading). Newer wins: if Kavita's progress for any chapter it covers changed after the
    /// mark was made (`madeAt`; read elsewhere meanwhile; for a chapter, not counting this
    /// device's own previous change still on its way), it's dropped quietly and the device
    /// follows Kavita at the next refresh. An unread mark that went then has this device's rows
    /// kept the newer (`KavitaReadMarkSettling`); best effort: if that read-back fails, the mark
    /// still counts as sent (retrying it would only find its own newer date and end quietly).
    private func send(_ mark: KavitaReadMarkPayload, _ job: OutboxJob) async throws {
        if let made = mark.account, let current = account(), current != made {
            throw OutboxWait("Waiting for the Kavita account it was marked under.")
        }
        guard let client = try makeClient() else {
            throw ConnectionError.message("Kavita isn't set up.")
        }
        do {
            if let chapterId = mark.chapterId {
                let server = try await client.progress(chapterId: chapterId)
                guard try KavitaProgressCheck.stillGoes(madeAt: mark.madeAt, server: server, chapterId: chapterId, seriesId: mark.seriesId,
                                                        outbox: outbox, excluding: job.id) else { return }
                try await client.markRead(mark.mark == .read, seriesId: mark.seriesId, chapterIds: [chapterId])
                if mark.mark == .unread, let settling, let date = try? await client.progress(chapterId: chapterId).lastModifiedUtc {
                    try? settling.settle(mark, kavitaDates: [chapterId: date])
                }
            } else {
                let chapters = try await client.volumes(seriesId: mark.seriesId).flatMap(\.0.chapters)
                if chapters.contains(where: { ($0.lastReadingProgressUtc ?? .distantPast) > mark.madeAt }) { return }
                try await client.markSeriesRead(mark.mark == .read, seriesId: mark.seriesId)
                if mark.mark == .unread, let settling, let after = try? await client.volumes(seriesId: mark.seriesId).flatMap(\.0.chapters) {
                    try? settling.settle(mark, kavitaDates: Dictionary(after.compactMap { c in c.lastReadingProgressUtc.map { (c.id, $0) } },
                                                                       uniquingKeysWith: max))
                }
            }
        } catch let error as ConnectionError {
            if case .server(let status) = error, (400..<500).contains(status), status != 408, status != 429 {
                throw OutboxPermanentFailure("Kavita rejected the read mark (HTTP \(status)).")
            }
            throw error
        }
    }
}
