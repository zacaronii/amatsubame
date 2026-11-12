import Core
import Foundation

/// Delivers queued playback reports to Jellyfin.
public struct JellyfinProgressHandler: OutboxHandler {
    public let kind = OutboxJobKind.jellyfinProgress
    /// Built per send so changes in Settings take effect; nil when Jellyfin isn't set up.
    let makeClient: @Sendable () throws -> JellyfinClient?
    let now: @Sendable () -> Date
    /// Reports older than this (queued while offline) are checked against the server first.
    static let staleAfter: TimeInterval = 120

    public init(makeClient: @escaping @Sendable () throws -> JellyfinClient?, now: @escaping @Sendable () -> Date = Date.init) {
        self.makeClient = makeClient
        self.now = now
    }

    public func send(_ job: OutboxJob, media: [(field: String, url: URL)]) async throws {
        var payload: JellyfinProgressPayload
        do {
            payload = try job.decodePayload(JellyfinProgressPayload.self)
        } catch {
            throw OutboxPermanentFailure("Unreadable playback report: \(error.localizedDescription)")
        }
        guard let client = try makeClient() else {
            throw ConnectionError.message("Jellyfin isn't set up.")
        }
        do {
            let reportedAt = payload.reportedAt ?? job.updatedAt
            if now().timeIntervalSince(reportedAt) > Self.staleAfter {
                // The session is long over (sent late: offline, or the app was asleep). Only its
                // stop still matters, for the resume point; starts and progress would revive
                // a session Jellyfin has already closed.
                guard payload.event == .stopped else { return }
                // Newer wins: if this was watched elsewhere after the report was made, drop it.
                if let played = try await client.item(id: payload.itemId).userData?.lastPlayedDate, played > reportedAt {
                    return
                }
            }
            try await client.report(payload)
        } catch let error {
            if case .server(let status) = error, (400..<500).contains(status), status != 408, status != 429 {
                throw OutboxPermanentFailure("Jellyfin rejected the playback report (HTTP \(status)).")
            }
            throw error
        }
    }
}
