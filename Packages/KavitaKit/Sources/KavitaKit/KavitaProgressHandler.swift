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

    public init(account: @escaping @Sendable () -> String? = { nil }, sendsPageTurns: Bool = true,
                makeClient: @escaping @Sendable () throws -> KavitaClient?) {
        self.account = account
        self.sendsPageTurns = sendsPageTurns
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
            // Newer wins: if the server moved on after this was queued (e.g. reading in
            // Kavita's web reader meanwhile), don't overwrite it with older progress.
            if let serverDate = try await client.progress(chapterId: payload.chapterId).lastModifiedUtc,
               serverDate > job.updatedAt {
                return
            }
            try await client.saveProgress(payload)
        } catch let error {
            if case .server(let status) = error, (400..<500).contains(status), status != 408, status != 429 {
                throw OutboxPermanentFailure("Kavita rejected the progress update (HTTP \(status)).")
            }
            throw error
        }
    }

    /// A mark, through Kavita's mark endpoints (never `Reader/progress`, which would record it
    /// as reading). Newer wins as for a page turn: if Kavita's progress for any chapter it covers
    /// changed after the mark was made (read elsewhere meanwhile), it's dropped quietly and the
    /// device follows Kavita at the next refresh.
    private func send(_ mark: KavitaReadMarkPayload, _ job: OutboxJob) async throws {
        if let made = mark.account, let current = account(), current != made {
            throw OutboxWait("Waiting for the Kavita account it was marked under.")
        }
        guard let client = try makeClient() else {
            throw ConnectionError.message("Kavita isn't set up.")
        }
        do {
            if let chapterId = mark.chapterId {
                if let changed = try await client.progress(chapterId: chapterId).lastModifiedUtc, changed > job.updatedAt { return }
                try await client.markRead(mark.mark == .read, seriesId: mark.seriesId, chapterIds: [chapterId])
            } else {
                let chapters = try await client.volumes(seriesId: mark.seriesId).flatMap(\.0.chapters)
                if chapters.contains(where: { ($0.lastReadingProgressUtc ?? .distantPast) > job.updatedAt }) { return }
                try await client.markSeriesRead(mark.mark == .read, seriesId: mark.seriesId)
            }
        } catch let error {
            if case .server(let status) = error, (400..<500).contains(status), status != 408, status != 429 {
                throw OutboxPermanentFailure("Kavita rejected the read mark (HTTP \(status)).")
            }
            throw error
        }
    }
}
