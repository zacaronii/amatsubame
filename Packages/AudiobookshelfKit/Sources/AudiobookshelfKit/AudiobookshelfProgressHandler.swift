import Core
import Foundation

/// A listening position for Audiobookshelf, queued in the outbox (coalesced per episode).
public struct AudiobookshelfProgressPayload: Codable, Equatable, Sendable {
    public var itemId: String
    public var episodeId: String
    public var currentTime: Double
    public var duration: Double
    public var isFinished: Bool
    public var reportedAt: Date

    public init(itemId: String, episodeId: String, currentTime: Double, duration: Double, isFinished: Bool, reportedAt: Date) {
        self.itemId = itemId
        self.episodeId = episodeId
        self.currentTime = currentTime
        self.duration = duration
        self.isFinished = isFinished
        self.reportedAt = reportedAt
    }

    public var coalesceKey: String { "abs-progress:\(itemId)/\(episodeId)" }
}

/// Delivers queued listening positions to Audiobookshelf.
public struct AudiobookshelfProgressHandler: OutboxHandler {
    public let kind = OutboxJobKind.audiobookshelfProgress
    /// Built per send so changes in Settings take effect; nil when Audiobookshelf isn't set up.
    let makeClient: @Sendable () throws -> AudiobookshelfClient?
    let now: @Sendable () -> Date
    /// Positions older than this (queued while offline) are checked against the server first.
    static let staleAfter: TimeInterval = 120

    public init(makeClient: @escaping @Sendable () throws -> AudiobookshelfClient?, now: @escaping @Sendable () -> Date = Date.init) {
        self.makeClient = makeClient
        self.now = now
    }

    public func send(_ job: OutboxJob, media: [(field: String, url: URL)]) async throws {
        let payload: AudiobookshelfProgressPayload
        do {
            payload = try job.decodePayload(AudiobookshelfProgressPayload.self)
        } catch {
            throw OutboxPermanentFailure("Unreadable listening position: \(error.localizedDescription)")
        }
        guard let client = try makeClient() else {
            throw ConnectionError.message("Audiobookshelf isn't set up.")
        }
        do {
            if now().timeIntervalSince(payload.reportedAt) > Self.staleAfter,
               let server = try await client.progress(itemId: payload.itemId, episodeId: payload.episodeId),
               server.updatedAt > payload.reportedAt {
                // Newer wins: listened to elsewhere since (the web player, another device).
                return
            }
            try await client.updateProgress(itemId: payload.itemId, episodeId: payload.episodeId,
                                            .init(currentTime: payload.currentTime, duration: payload.duration, isFinished: payload.isFinished))
        } catch let error {
            if case .server(let status) = error, (400..<500).contains(status), status != 408, status != 429 {
                throw OutboxPermanentFailure("Audiobookshelf rejected the listening position (HTTP \(status)).")
            }
            throw error
        }
    }
}
