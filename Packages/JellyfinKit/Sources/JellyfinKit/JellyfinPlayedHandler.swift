import Core
import Foundation

/// An item marked watched or unwatched by hand, queued in the outbox (kind `jellyfinPlayed`).
/// The newest mark for an item replaces one still waiting.
public struct JellyfinPlayedPayload: Codable, Equatable, Sendable {
    public var itemId: String
    public var played: Bool

    public init(itemId: String, played: Bool) {
        self.itemId = itemId
        self.played = played
    }

    public var coalesceKey: String { "jellyfin.item.\(itemId).played" }
}

public extension JellyfinClient {
    /// Marks an item watched (`POST /Users/{id}/PlayedItems/{item}`) or unwatched (`DELETE`,
    /// which also clears its resume point). Checked against Jellyfin on 2026-11-22.
    func setPlayed(itemId: String, played: Bool) async throws(ConnectionError) {
        guard let userId else { throw .message("Not signed in to Jellyfin.") }
        var request = URLRequest(url: baseURL.appending(path: "Users/\(userId)/PlayedItems/\(itemId)"))
        request.httpMethod = played ? "POST" : "DELETE"
        _ = try await http.send(authorize(request))
    }
}

/// Delivers queued watched marks to Jellyfin.
public struct JellyfinPlayedHandler: OutboxHandler {
    public let kind = OutboxJobKind.jellyfinPlayed
    let makeClient: @Sendable () throws -> JellyfinClient?
    /// Called with the item's id once Jellyfin has the mark (lists reload then).
    let didSend: @Sendable (String) -> Void

    public init(makeClient: @escaping @Sendable () throws -> JellyfinClient?, didSend: @escaping @Sendable (String) -> Void = { _ in }) {
        self.makeClient = makeClient
        self.didSend = didSend
    }

    public func send(_ job: OutboxJob, media: [(field: String, url: URL)]) async throws {
        let payload: JellyfinPlayedPayload
        do {
            payload = try job.decodePayload(JellyfinPlayedPayload.self)
        } catch {
            throw OutboxPermanentFailure("Unreadable watched mark: \(error.localizedDescription)")
        }
        guard let client = try makeClient() else {
            throw ConnectionError.message("Jellyfin isn't set up.")
        }
        do {
            try await client.setPlayed(itemId: payload.itemId, played: payload.played)
            didSend(payload.itemId)
        } catch let error {
            if case .server(let status) = error, (400..<500).contains(status), status != 408, status != 429 {
                throw OutboxPermanentFailure("Jellyfin rejected the watched mark (HTTP \(status)).")
            }
            throw error
        }
    }
}
