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
        public var createdAt: String?
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
    public var jobs: [String: Int]?
    /// Whether Kaku can transcribe Jellyfin episodes (1.4).
    public var jellyfin: Bool?
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
    @discardableResult
    public func requestJob(itemId: String, episodeId: String) async throws(ConnectionError) -> KakuJob? {
        struct Body: Encodable {
            var itemId: String
            var episodeId: String
        }
        let request: URLRequest
        do {
            request = try .json("POST", baseURL.appending(path: "jobs"), body: Body(itemId: itemId, episodeId: episodeId))
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
