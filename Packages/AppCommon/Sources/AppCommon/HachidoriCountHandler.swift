import Core
import Foundation
import HachidoriKit

/// Sends queued lookups to the Hachidori host (`hd_lookup_stats_record`), one at a time: the host
/// has no batch form (docs/hachidori.md section 4). Each one sent is taken off the job at once,
/// so a retry sends only the rest.
struct HachidoriCountHandler: OutboxHandler {
    let kind = OutboxJobKind.hachidoriLookupCount
    let store: OutboxStore
    /// The link while Hachidori is on; nil once it's turned off.
    let link: @Sendable @MainActor () -> HachidoriLink?

    struct NotLinked: Error, LocalizedError {
        var errorDescription: String? { "Hachidori isn't reachable." }
    }

    func send(_ job: OutboxJob, media: [(field: String, url: URL)]) async throws {
        // Turned off: the lookups have nowhere to go.
        guard let link = await link() else { return }
        guard case .linked = await link.status, let id = job.id else { throw NotLinked() }
        var payload = try job.decodePayload(HostLookupCountJob.self)
        while payload.count > 0 {
            do {
                // Nil: the host has lookup counts turned off, so nothing more to send.
                guard try await link.recordLookup(term: payload.term, reading: payload.reading) != nil else { return }
            } catch HachidoriError.outcomeUnknown {
                // Sent, but the link dropped before the reply: like Hachidori, never sent again.
            }
            payload.count -= 1
            try store.saveProgress(id, payload: JSONEncoder().encode(payload))
        }
    }
}
