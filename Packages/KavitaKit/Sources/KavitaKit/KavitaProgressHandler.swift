import Core
import Foundation

/// Delivers queued reading progress to Kavita.
public struct KavitaProgressHandler: OutboxHandler {
    public let kind = OutboxJobKind.kavitaProgress
    /// Built per send so changes in Settings take effect; nil when Kavita isn't set up.
    let makeClient: @Sendable () throws -> KavitaClient?

    public init(makeClient: @escaping @Sendable () throws -> KavitaClient?) {
        self.makeClient = makeClient
    }

    public func send(_ job: OutboxJob, media: [(field: String, url: URL)]) async throws {
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
}
