import Core
import Foundation

// Verified against Audiobookshelf 2.36.1 (2026-11-05):
// - `GET /status` is anonymous: app, serverVersion.
// - `POST /login` {username, password} with `x-return-tokens: true` returns user.accessToken
//   (an hour) and user.refreshToken (30 days); bad credentials are 401.
// - `POST /auth/refresh` with `x-refresh-token` returns new ones the same way.
// - An API key (Settings ▸ API Keys) works as a bearer token too, without refresh.
// - Audio files answer byte ranges (206), so they stream.

/// The bearer token in use and, after a sign-in, how to renew it. Shared by every client
/// made from the same account so a refresh happens once.
public actor AudiobookshelfTokens {
    private let secrets: any SecretStore
    private var refreshing: Task<String, any Error>?

    public init(secrets: any SecretStore) {
        self.secrets = secrets
    }

    func current() throws -> String? {
        try secrets.secret(for: .audiobookshelfToken)
    }

    /// The token, renewed first when it runs out within five minutes: an audio stream keeps the
    /// token it started with, so it must last. Kept as it is when renewing fails.
    func fresh(baseURL: URL, http: HTTPClient) async throws -> String? {
        guard let token = try current() else { return nil }
        guard let expiry = Self.expiry(token), expiry < .now.addingTimeInterval(5 * 60) else { return token }
        return (try? await refresh(baseURL: baseURL, http: http)) ?? token
    }

    /// When a JWT access token runs out (its `exp`); nil for one that doesn't say (an API key).
    static func expiry(_ token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var payload = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = claims["exp"] as? Double else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    /// Swaps the refresh token for a new pair; nil when there's none (an API key).
    func refresh(baseURL: URL, http: HTTPClient) async throws -> String? {
        if let refreshing { return try await refreshing.value }
        guard let refreshToken = try secrets.secret(for: .audiobookshelfRefreshToken) else { return nil }
        let task = Task { [secrets] () async throws -> String in
            var request = URLRequest(url: baseURL.appending(path: "auth/refresh"))
            request.httpMethod = "POST"
            request.setValue(refreshToken, forHTTPHeaderField: "x-refresh-token")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let user = try await http.decode(AudiobookshelfLogin.self, from: request).user
            guard let access = user.accessToken else { throw ConnectionError.unexpectedResponse("No access token in the refresh answer.") }
            try secrets.setSecret(access, for: .audiobookshelfToken)
            if let next = user.refreshToken { try secrets.setSecret(next, for: .audiobookshelfRefreshToken) }
            return access
        }
        refreshing = task
        defer { refreshing = nil }
        return try await task.value
    }
}

public struct AudiobookshelfClient: Sendable {
    public let baseURL: URL
    public let http: HTTPClient
    /// Nil for sign-in only.
    let tokens: AudiobookshelfTokens?

    public init(baseURL: URL, tokens: AudiobookshelfTokens? = nil, http: HTTPClient = HTTPClient()) {
        self.baseURL = baseURL
        self.tokens = tokens
        self.http = http
    }

    // MARK: Signing in

    public func status() async throws(ConnectionError) -> AudiobookshelfStatus {
        let status: AudiobookshelfStatus
        do {
            status = try await http.decode(AudiobookshelfStatus.self, from: .get(baseURL.appending(path: "status")))
        } catch .unexpectedResponse, .server(status: 404) {
            throw .notThisService("Expected an Audiobookshelf server.")
        }
        guard status.app == nil || status.app == "audiobookshelf" else { throw .notThisService("Expected an Audiobookshelf server.") }
        return status
    }

    /// Signs in; the answer carries the access and refresh tokens to keep.
    public func login(username: String, password: String) async throws(ConnectionError) -> AudiobookshelfUser {
        struct Body: Encodable {
            var username: String
            var password: String
        }
        var request: URLRequest
        do {
            request = try .json("POST", baseURL.appending(path: "login"), body: Body(username: username, password: password))
        } catch {
            throw .message(error.localizedDescription)
        }
        request.setValue("true", forHTTPHeaderField: "x-return-tokens")
        return try await http.decode(AudiobookshelfLogin.self, from: request).user
    }

    // MARK: Browsing

    public func me() async throws(ConnectionError) -> AudiobookshelfUser {
        try await get(AudiobookshelfUser.self, "api/me")
    }

    public func libraries() async throws(ConnectionError) -> [AudiobookshelfLibrary] {
        try await get(AudiobookshelfLibraries.self, "api/libraries").libraries
    }

    /// Every show in a library, a page at a time.
    public func items(libraryId: String, pageSize: Int = 200) async throws(ConnectionError) -> [AudiobookshelfItem] {
        var items: [AudiobookshelfItem] = []
        var page = 0
        while true {
            let answer = try await get(AudiobookshelfItemPage.self, "api/libraries/\(libraryId)/items",
                                       query: [URLQueryItem(name: "limit", value: "\(pageSize)"), URLQueryItem(name: "page", value: "\(page)")])
            items += answer.results
            page += 1
            if answer.results.isEmpty || items.count >= answer.total { return items }
        }
    }

    /// One show with all its episodes.
    public func item(id: String) async throws(ConnectionError) -> AudiobookshelfItem {
        try await get(AudiobookshelfItem.self, "api/items/\(id)", query: [URLQueryItem(name: "expanded", value: "1")])
    }

    /// The newest episodes in a podcast library, with their show.
    public func recentEpisodes(libraryId: String, limit: Int = 25) async throws(ConnectionError) -> [AudiobookshelfEpisode] {
        try await get(AudiobookshelfEpisodes.self, "api/libraries/\(libraryId)/recent-episodes",
                      query: [URLQueryItem(name: "limit", value: "\(limit)")]).episodes
    }

    /// Shows with an episode in progress, the most recent first.
    public func itemsInProgress(limit: Int = 25) async throws(ConnectionError) -> [AudiobookshelfItem] {
        try await get(AudiobookshelfItemsInProgress.self, "api/me/items-in-progress",
                      query: [URLQueryItem(name: "limit", value: "\(limit)")]).libraryItems
    }

    /// The listener's place in one episode (or a book, with an empty episode id); nil when it was never started.
    public func progress(itemId: String, episodeId: String) async throws(ConnectionError) -> AudiobookshelfProgress? {
        do {
            return try await get(AudiobookshelfProgress.self, "api/me/progress/\(AudiobookshelfProgress.path(itemId: itemId, episodeId: episodeId))")
        } catch .server(status: 404) {
            return nil
        }
    }

    // MARK: Media

    /// The cover, signed (for `AsyncImage`-style loaders that take a request).
    public func coverRequest(itemId: String, width: Int = 400) async throws(ConnectionError) -> URLRequest {
        try await authorized(URLRequest(url: url("api/items/\(itemId)/cover", query: [URLQueryItem(name: "width", value: "\(width)")])))
    }

    /// An episode's audio file, signed: streams with AVPlayer (byte ranges) or downloads.
    public func audioRequest(itemId: String, ino: String) async throws(ConnectionError) -> URLRequest {
        try await authorized(URLRequest(url: url("api/items/\(itemId)/file/\(ino)")))
    }

    // MARK: Progress

    public struct ProgressUpdate: Codable, Equatable, Sendable {
        public var currentTime: Double
        public var duration: Double
        public var progress: Double
        public var isFinished: Bool

        public init(currentTime: Double, duration: Double, isFinished: Bool) {
            self.currentTime = currentTime
            self.duration = duration
            progress = duration > 0 ? min(max(currentTime / duration, 0), 1) : 0
            self.isFinished = isFinished
        }
    }

    public func updateProgress(itemId: String, episodeId: String, _ update: ProgressUpdate) async throws(ConnectionError) {
        let request: URLRequest
        do {
            request = try .json("PATCH", url("api/me/progress/\(AudiobookshelfProgress.path(itemId: itemId, episodeId: episodeId))"), body: update)
        } catch {
            throw .message(error.localizedDescription)
        }
        _ = try await send(request)
    }

    // MARK: Plumbing

    func url(_ path: String, query: [URLQueryItem] = []) -> URL {
        let url = baseURL.appending(path: path)
        return query.isEmpty ? url : url.appending(queryItems: query)
    }

    private func get<T: Decodable>(_ type: T.Type, _ path: String, query: [URLQueryItem] = []) async throws(ConnectionError) -> T {
        let result = try await send(.get(url(path, query: query)))
        do {
            return try JSONDecoder().decode(T.self, from: result.data)
        } catch {
            throw .unexpectedResponse(String(describing: error))
        }
    }

    private func authorized(_ request: URLRequest) async throws(ConnectionError) -> URLRequest {
        var request = request
        let token: String?
        do {
            token = try await tokens?.fresh(baseURL: baseURL, http: http)
        } catch {
            throw .message(error.localizedDescription)
        }
        guard let token else { throw .unauthorized }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// Sends with the current token; an expired one is refreshed once and the request retried.
    private func send(_ request: URLRequest) async throws(ConnectionError) -> HTTPResponse {
        do {
            return try await http.send(authorized(request))
        } catch .unauthorized {
            let renewed: String?
            do {
                renewed = try await tokens?.refresh(baseURL: baseURL, http: http)
            } catch {
                throw .unauthorized
            }
            guard let renewed else { throw .unauthorized }
            var retry = request
            retry.setValue("Bearer \(renewed)", forHTTPHeaderField: "Authorization")
            return try await http.send(retry)
        }
    }
}
