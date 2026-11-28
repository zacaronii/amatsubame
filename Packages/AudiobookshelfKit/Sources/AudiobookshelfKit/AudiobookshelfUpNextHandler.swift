import Core
import Foundation

/// Kiku's Up Next for one podcast library, queued in the outbox as the whole list (coalesced
/// per library: only the latest matters).
public struct AudiobookshelfUpNextPayload: Codable, Equatable, Sendable {
    public var libraryId: String
    public var items: [UpNextItem]

    public init(libraryId: String, items: [UpNextItem]) {
        self.libraryId = libraryId
        self.items = items
    }

    public var coalesceKey: String { "abs-upnext:\(libraryId)" }
}

/// Makes the library's "Up Next" playlist on Audiobookshelf hold the queued list, in order.
/// The playlist is the one Kiku made (its id kept here), else one of the user's own named
/// "Up Next" in that library, else a new one. Audiobookshelf deletes a playlist when its last
/// item goes and only reorders the same items, so new items go in before old ones come out,
/// then the order is set. Deleted elsewhere meanwhile (404), it's found or made again once in
/// the same send; a second time, the job fails for good rather than looping.
public struct AudiobookshelfUpNextHandler: OutboxHandler {
    public static let playlistName = "Up Next"
    public let kind = OutboxJobKind.audiobookshelfUpNext
    let makeClient: @Sendable () throws -> AudiobookshelfClient?
    let store: UpNextStore

    public init(store: UpNextStore, makeClient: @escaping @Sendable () throws -> AudiobookshelfClient?) {
        self.store = store
        self.makeClient = makeClient
    }

    public func send(_ job: OutboxJob, media: [(field: String, url: URL)]) async throws {
        let payload: AudiobookshelfUpNextPayload
        do {
            payload = try job.decodePayload(AudiobookshelfUpNextPayload.self)
        } catch {
            throw OutboxPermanentFailure("Unreadable Up Next: \(error.localizedDescription)")
        }
        guard let client = try makeClient() else { throw ConnectionError.message("Audiobookshelf isn't set up.") }
        do {
            try await apply(payload, client: client)
        } catch .server(404) {
            // Gone while this ran: start again from no playlist, once.
            try store.setPlaylistId(nil, libraryId: payload.libraryId)
            do {
                try await apply(payload, client: client)
            } catch .server(404) {
                throw OutboxPermanentFailure("Audiobookshelf's Up Next playlist kept disappearing.")
            } catch {
                throw Self.classify(error)
            }
        } catch {
            throw Self.classify(error)
        }
    }

    private func apply(_ payload: AudiobookshelfUpNextPayload, client: AudiobookshelfClient) async throws(ConnectionError) {
        let library = payload.libraryId
        let wanted = payload.items.map { AudiobookshelfPlaylist.Item(libraryItemId: $0.itemId, episodeId: $0.episodeId) }
        var playlist: AudiobookshelfPlaylist?
        if let id = try? store.playlistId(libraryId: library) { playlist = try await client.playlist(id: id) }
        if playlist == nil {
            playlist = try await client.playlists(libraryId: library).first { $0.name == Self.playlistName }
        }
        guard let playlist else {
            guard !wanted.isEmpty else { return }
            let made = try await client.createPlaylist(libraryId: library, name: Self.playlistName, items: wanted)
            try? store.setPlaylistId(made.id, libraryId: library)
            return
        }
        try? store.setPlaylistId(playlist.id, libraryId: library)
        let current = playlist.items
        let adding = wanted.filter { !current.contains($0) }
        let removing = current.filter { !wanted.contains($0) }
        if !adding.isEmpty { try await client.addToPlaylist(id: playlist.id, items: adding) }
        if !removing.isEmpty {
            try await client.removeFromPlaylist(id: playlist.id, items: removing)
            // Emptied: Audiobookshelf deleted it.
            if wanted.isEmpty { try? store.setPlaylistId(nil, libraryId: library); return }
        }
        let after = current.filter { wanted.contains($0) } + adding
        if after != wanted { try await client.reorderPlaylist(id: playlist.id, items: wanted) }
    }

    static func classify(_ error: Error) -> Error {
        if case .server(let status) = error as? ConnectionError, (400..<500).contains(status), status != 408, status != 429 {
            return OutboxPermanentFailure("Audiobookshelf refused the Up Next change (HTTP \(status)).")
        }
        return error
    }
}
