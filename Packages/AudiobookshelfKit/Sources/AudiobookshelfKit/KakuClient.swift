import Core
import Foundation

// Kaku's API (docs/kaku.md): a bearer token on everything but /health.

/// A Kaku transcript: sentences on the episode's timeline, with word timings.
public struct KakuTranscript: Decodable, Equatable, Sendable {
    public struct Item: Decodable, Equatable, Sendable {
        public var libraryItemId: String
        public var episodeId: String
        public var libraryId: String?
    }

    public struct Source: Decodable, Equatable, Sendable {
        public var fingerprint: String
        public var duration: Double?
        public var model: String?
        /// Kaku's version when it made the transcript.
        public var kaku: String?
        public var createdAt: String?

        /// `createdAt` as a date.
        public var created: Date? {
            createdAt.flatMap { try? Date($0, strategy: .iso8601) }
        }
    }

    public struct Sentence: Decodable, Equatable, Sendable {
        public var start: Double
        public var end: Double
        public var text: String
        public var confidence: Double?
        public var words: [Word]
    }

    public struct Word: Decodable, Equatable, Sendable {
        public var text: String
        public var start: Double
        public var end: Double
        public var confidence: Double?
    }

    public var item: Item
    public var source: Source
    public var sentences: [Sentence]
}

/// Where an episode is in Kaku's queue.
public struct KakuJob: Decodable, Equatable, Sendable {
    public enum State: String, Decodable, Sendable {
        case queued, running, done, failed
    }

    public var itemId: String
    public var episodeId: String
    public var state: State
    /// 0–1 while running.
    public var progress: Double?
    /// Jobs ahead of it.
    public var position: Int?
    public var error: String?
}

public enum KakuTranscriptAnswer: Equatable, Sendable {
    case ready(KakuTranscript)
    case pending(KakuJob)
    /// Kaku has neither (its library is off, or it hasn't seen the episode yet).
    case missing
}

/// One episode's transcript state, for badges.
public enum KakuStatus: String, Codable, Equatable, Sendable {
    case done, queued, running, failed, missing
}

/// A Jellyfin episode Kaku was asked to transcribe (Kaku 1.4), for Miru's subtitles.
public struct KakuJellyfinJob: Decodable, Equatable, Sendable {
    public enum State: String, Decodable, Sendable {
        case done, queued, running, failed, missing
        /// Not in Jellyfin, or its audio isn't Japanese.
        case unavailable
    }

    /// The Jellyfin item id.
    public var itemId: String
    public var state: State
    public var progress: Double?
    public var position: Int?
    public var error: String?

    public init(itemId: String, state: State, progress: Double? = nil, position: Int? = nil, error: String? = nil) {
        self.itemId = itemId
        self.state = state
        self.progress = progress
        self.position = position
        self.error = error
    }
}

public enum KakuSubtitlesAnswer: Equatable, Sendable {
    /// SubRip text.
    case ready(String)
    case pending(KakuJellyfinJob)
    case missing
}

public struct KakuHealth: Decodable, Equatable, Sendable {
    public var version: String
    public var model: String?
    /// The model is in GPU memory (it unloads after 10 idle minutes).
    public var modelLoaded: Bool?
    public var gpu: GPU?
    public var jobs: [String: Int]?
    /// When Kaku last checked Audiobookshelf for new episodes (seconds since 1970), and what went wrong then.
    public var lastPoll: Double?
    public var lastPollError: String?
    /// Whether Kaku can transcribe Jellyfin episodes (1.4).
    public var jellyfin: Bool?

    public struct GPU: Decodable, Equatable, Sendable {
        public var usedMB: Int
        public var totalMB: Int
    }
}

/// Kaku's work (`GET /jobs`): what's running, the queue, recent failures, and a rough time left.
public struct KakuQueue: Decodable, Equatable, Sendable {
    public var running: KakuQueueJob?
    public var queued: [KakuQueueJob]
    public var counts: [String: Int]
    public var failed: [KakuQueueJob]
    /// The recent average time per job, and for the whole queue (Kaku 1.5).
    public var averageSeconds: Double?
    public var estimatedSeconds: Double?

    public var queuedCount: Int { counts["queued"] ?? queued.count }
}

/// A job in Kaku's queue, with its title.
public struct KakuQueueJob: Decodable, Equatable, Sendable, Identifiable {
    public var itemId: String
    public var episodeId: String
    /// An Audiobookshelf library's id, or "jellyfin" (its item id is then "jf:<Jellyfin id>").
    public var libraryId: String
    public var title: String
    public var state: KakuJob.State
    /// now (asked for), new (added in the last week) or backlog.
    public var priority: String?
    public var progress: Double?
    public var error: String?
    public var attempts: Int?
    public var position: Int?

    public var id: String { "\(itemId)/\(episodeId)" }
    public var isJellyfin: Bool { libraryId == "jellyfin" }
}

/// Audiobookshelf's libraries as Kaku sees them (on or off), with how far along each is.
public struct KakuLibraries: Decodable, Equatable, Sendable {
    public var libraries: [KakuLibrary]
    /// Jellyfin episodes asked for by Miru (Kaku 1.5); nil when Kaku has no Jellyfin set up.
    public var jellyfin: KakuLibraryProgress?
}

public struct KakuLibrary: Decodable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var mediaType: AudiobookshelfLibrary.MediaType
    public var enabled: Bool
    /// Kaku 1.5; nil from an older Kaku.
    public var counts: KakuLibraryProgress.Counts?
    public var lastTranscribed: Double?

    public var progress: KakuLibraryProgress? { counts.map { KakuLibraryProgress(counts: $0, lastTranscribed: lastTranscribed) } }
}

public struct KakuLibraryProgress: Decodable, Equatable, Sendable {
    public struct Counts: Decodable, Equatable, Sendable {
        public var done: Int
        public var queued: Int
        public var running: Int
        public var failed: Int

        public var total: Int { done + queued + running + failed }
    }

    public var counts: Counts
    /// When its last transcript was made (seconds since 1970).
    public var lastTranscribed: Double?
}

public struct KakuClient: Sendable {
    public let baseURL: URL
    let token: String
    public let http: HTTPClient

    public init(baseURL: URL, token: String, http: HTTPClient = HTTPClient()) {
        self.baseURL = baseURL
        self.token = token
        self.http = http
    }

    /// Anonymous: checks the URL; `authorizedCheck` checks the token too.
    public func health() async throws(ConnectionError) -> KakuHealth {
        do {
            return try await http.decode(KakuHealth.self, from: .get(baseURL.appending(path: "health")))
        } catch .unexpectedResponse, .server(status: 404) {
            throw .notThisService("Expected a Kaku server.")
        }
    }

    /// Fails with `.unauthorized` when the token is wrong.
    public func authorizedCheck() async throws(ConnectionError) {
        _ = try await http.send(authorize(.get(baseURL.appending(path: "jobs").appending(queryItems: [URLQueryItem(name: "limit", value: "1")]))))
    }

    public func transcript(itemId: String, episodeId: String) async throws(ConnectionError) -> KakuTranscriptAnswer {
        let result = try await http.sendRaw(authorize(.get(baseURL.appending(path: "transcripts/\(AudiobookshelfProgress.path(itemId: itemId, episodeId: episodeId))"))))
        switch result.response.statusCode {
        case 200: return .ready(try decode(KakuTranscript.self, result.data))
        case 202: return .pending(try decode(KakuJob.self, result.data))
        case 404: return .missing
        case 401, 403: throw .unauthorized
        case let status: throw .server(status: status)
        }
    }

    /// A part of the audio as AAC in .m4a (60 s at most), cut by Kaku from Audiobookshelf: card
    /// audio for a streamed episode or book without downloading all of it.
    public func clip(itemId: String, episodeId: String, start: Double, end: Double) async throws(ConnectionError) -> Data {
        let url = baseURL.appending(path: "clips/\(AudiobookshelfProgress.path(itemId: itemId, episodeId: episodeId))").appending(queryItems: [
            URLQueryItem(name: "start", value: String(format: "%.3f", max(start, 0))),
            URLQueryItem(name: "end", value: String(format: "%.3f", end)),
        ])
        let result = try await http.send(authorize(.get(url)))
        guard !result.data.isEmpty else { throw .unexpectedResponse("Kaku sent an empty clip.") }
        return result.data
    }

    /// Asks for an episode (or a book, with an empty episode id) now (top of the queue). Nil when it's already done.
    /// `force` (Kaku 1.6) transcribes it again even though its transcript is current; the old
    /// one serves until the new one replaces it.
    @discardableResult
    public func requestJob(itemId: String, episodeId: String, force: Bool = false) async throws(ConnectionError) -> KakuJob? {
        struct Body: Encodable {
            var itemId: String
            var episodeId: String
            var force: Bool?
        }
        let request: URLRequest
        do {
            request = try .json("POST", baseURL.appending(path: "jobs"), body: Body(itemId: itemId, episodeId: episodeId, force: force ? true : nil))
        } catch {
            throw .message(error.localizedDescription)
        }
        let result = try await http.send(authorize(request))
        return result.response.statusCode == 202 ? try decode(KakuJob.self, result.data) : nil
    }

    /// Transcript states for many episodes at once, keyed "<item id>/<episode id>".
    public func status(_ episodes: [(itemId: String, episodeId: String)]) async throws(ConnectionError) -> [String: KakuStatus] {
        struct Body: Encodable {
            struct Episode: Encodable {
                var itemId: String
                var episodeId: String
            }
            var episodes: [Episode]
        }
        struct Answer: Decodable {
            var statuses: [String: KakuStatus]
        }
        guard !episodes.isEmpty else { return [:] }
        let request: URLRequest
        do {
            request = try .json("POST", baseURL.appending(path: "transcripts/status"),
                                body: Body(episodes: episodes.map { .init(itemId: $0.itemId, episodeId: $0.episodeId) }))
        } catch {
            throw .message(error.localizedDescription)
        }
        return try decode(Answer.self, try await http.send(authorize(request)).data).statuses
    }

    // MARK: The server (Kaku's screen in Settings)

    public func queue(limit: Int = 50) async throws(ConnectionError) -> KakuQueue {
        let url = baseURL.appending(path: "jobs").appending(queryItems: [URLQueryItem(name: "limit", value: "\(limit)")])
        return try decode(KakuQueue.self, try await http.send(authorize(.get(url))).data)
    }

    public func libraries() async throws(ConnectionError) -> KakuLibraries {
        try decode(KakuLibraries.self, try await http.send(authorize(.get(baseURL.appending(path: "libraries")))).data)
    }

    /// Switches these libraries on and every other one off; Kaku answers with the new list.
    public func setLibraries(enabled: [String]) async throws(ConnectionError) -> KakuLibraries {
        struct Body: Encodable {
            var enabled: [String]
        }
        let request: URLRequest
        do {
            request = try .json("PUT", baseURL.appending(path: "libraries"), body: Body(enabled: enabled))
        } catch {
            throw .message(error.localizedDescription)
        }
        return try decode(KakuLibraries.self, try await http.send(authorize(request)).data)
    }

    /// Try Again for a failed job: asked for again at the top of the queue.
    public func retry(_ job: KakuQueueJob) async throws(ConnectionError) {
        if job.isJellyfin {
            _ = try await requestJellyfin([String(job.itemId.dropFirst("jf:".count))])
        } else {
            try await requestJob(itemId: job.itemId, episodeId: job.episodeId)
        }
    }

    // MARK: Jellyfin (Kaku 1.4)

    /// Asks for Jellyfin episodes now, in this order (an episode, or the rest of a season).
    public func requestJellyfin(_ itemIds: [String]) async throws(ConnectionError) -> [KakuJellyfinJob] {
        struct Answer: Decodable {
            var jobs: [KakuJellyfinJob]
        }
        guard !itemIds.isEmpty else { return [] }
        let result = try await http.send(authorize(try jellyfinRequest("jellyfin/jobs", itemIds)))
        return try decode(Answer.self, result.data).jobs
    }

    /// An episode's subtitles as SubRip, or its place in the queue.
    public func jellyfinSubtitles(itemId: String) async throws(ConnectionError) -> KakuSubtitlesAnswer {
        let url = baseURL.appending(path: "jellyfin/transcripts/\(itemId)").appending(queryItems: [URLQueryItem(name: "format", value: "srt")])
        let result = try await http.sendRaw(authorize(.get(url)))
        switch result.response.statusCode {
        case 200:
            guard let text = String(data: result.data, encoding: .utf8) else { throw .unexpectedResponse("Kaku's subtitles aren't UTF-8.") }
            return .ready(text)
        case 202: return .pending(try decode(KakuJellyfinJob.self, result.data))
        case 404: return .missing
        case 401, 403: throw .unauthorized
        case let status: throw .server(status: status)
        }
    }

    /// Which Jellyfin episodes have subtitles from Kaku, by item id.
    public func jellyfinStatus(_ itemIds: [String]) async throws(ConnectionError) -> [String: KakuStatus] {
        struct Answer: Decodable {
            var statuses: [String: KakuStatus]
        }
        guard !itemIds.isEmpty else { return [:] }
        return try decode(Answer.self, try await http.send(authorize(try jellyfinRequest("jellyfin/transcripts/status", itemIds))).data).statuses
    }

    private func jellyfinRequest(_ path: String, _ itemIds: [String]) throws(ConnectionError) -> URLRequest {
        struct Body: Encodable {
            var itemIds: [String]
        }
        do {
            return try .json("POST", baseURL.appending(path: path), body: Body(itemIds: itemIds))
        } catch {
            throw .message(error.localizedDescription)
        }
    }

    private func authorize(_ request: URLRequest) -> URLRequest {
        var request = request
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws(ConnectionError) -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw .unexpectedResponse(String(describing: error))
        }
    }
}
