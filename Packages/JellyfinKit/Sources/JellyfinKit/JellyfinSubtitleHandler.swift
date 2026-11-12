import Core
import Foundation

/// A subtitle file to add to a Jellyfin item; the file itself is the job's `subtitle` media.
public struct JellyfinSubtitlePayload: Codable, Equatable, Sendable {
    public var itemId: String
    /// "srt", "ass" or "ssa".
    public var format: String
    /// Becomes part of the file name (`<episode>.<language>.<format>`): "ja", the usual
    /// language suffix, so tools like Shoko recognise it and move it next to the video.
    public var language: String
    /// A separate subtitle file on the server this one replaces (retimed server subtitles):
    /// it's removed first, but only while a stream still has this path.
    public var replacesPath: String?

    public init(itemId: String, format: String, language: String = "ja", replacesPath: String? = nil) {
        self.itemId = itemId
        self.format = format
        self.language = language
        self.replacesPath = replacesPath
    }
}

/// Uploads queued subtitle files to Jellyfin.
public struct JellyfinSubtitleHandler: OutboxHandler {
    public static let mediaField = "subtitle"
    public let kind = OutboxJobKind.jellyfinSubtitle
    let makeClient: @Sendable () throws -> JellyfinClient?
    /// Called with the item id once Jellyfin has the file.
    let didUpload: @Sendable (String) -> Void

    public init(makeClient: @escaping @Sendable () throws -> JellyfinClient?, didUpload: @escaping @Sendable (String) -> Void = { _ in }) {
        self.makeClient = makeClient
        self.didUpload = didUpload
    }

    public func send(_ job: OutboxJob, media: [(field: String, url: URL)]) async throws {
        let payload: JellyfinSubtitlePayload
        let data: Data
        do {
            payload = try job.decodePayload(JellyfinSubtitlePayload.self)
            guard let file = media.first(where: { $0.field == Self.mediaField }) else { throw CocoaError(.fileNoSuchFile) }
            data = try Data(contentsOf: file.url)
        } catch {
            throw OutboxPermanentFailure("Unreadable subtitle upload: \(error.localizedDescription)")
        }
        guard let client = try makeClient() else {
            throw ConnectionError.message("Jellyfin isn't set up.")
        }
        do {
            // Replacing: remove the old file, found by its path (indexes shift once it's gone, so
            // a retry after the delete finds nothing to remove).
            if let path = payload.replacesPath {
                let streams = try await client.item(id: payload.itemId).mediaSources?.first?.mediaStreams ?? []
                if let old = streams.first(where: { $0.isSubtitle && $0.isExternal == true && $0.path == path }) {
                    try await client.deleteSubtitle(itemId: payload.itemId, index: old.index)
                }
            }
            try await client.uploadSubtitle(itemId: payload.itemId, data: data, format: payload.format, language: payload.language)
        } catch let error {
            if case .unauthorized = error {
                throw OutboxPermanentFailure("Jellyfin didn't allow adding subtitles (it needs an admin, or \"Allow subtitle management\" for this user).")
            }
            if case .server(let status) = error, (400..<500).contains(status), status != 408, status != 429 {
                throw OutboxPermanentFailure("Jellyfin rejected the subtitles (HTTP \(status)).")
            }
            throw error
        }
        didUpload(payload.itemId)
    }
}
