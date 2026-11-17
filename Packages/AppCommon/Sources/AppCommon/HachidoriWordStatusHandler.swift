import Core
import Foundation
import HachidoriKit

/// Tells the Hachidori host about a word marked known or ignored (or cleared) here:
/// `hd_word_status_override`, which changes only that word, so marks from several apps and
/// browsers never conflict. The job names the word; the mark sent is the one it has now.
struct HachidoriWordStatusHandler: OutboxHandler {
    let kind = OutboxJobKind.hachidoriWordStatus
    let statuses: WordStatusStore
    /// The link while Hachidori is on; nil once it's turned off.
    let link: @Sendable @MainActor () -> HachidoriLink?

    func send(_ job: OutboxJob, media: [(field: String, url: URL)]) async throws {
        guard let link = await link() else { return }
        guard case .linked = await link.status else { throw HachidoriCountHandler.NotLinked() }
        let headword = try job.decodePayload(WordStatusJob.self).headword
        // Already sent (by this or another app), or Hachidori was turned off meanwhile.
        guard let record = try statuses.pendingHost().first(where: { $0.headword == headword }) else { return }
        do {
            try await link.setWordStatus(record.status.map { $0 == .known ? .known : .ignored }, for: headword)
        } catch HachidoriError.outcomeUnknown {
            // Sent, but the link dropped before the reply: the word stays waiting and is sent
            // again on the next link (setting the same mark twice changes nothing).
            return
        }
        try statuses.sentToHost(record)
    }
}
