import Core
import Foundation

/// A show (or movie) on Jimaku: a folder of subtitle files.
public struct JimakuEntry: Decodable, Identifiable, Hashable, Sendable {
    public struct Flags: Decodable, Hashable, Sendable {
        public var anime: Bool?
        public var movie: Bool?
        public var unverified: Bool?
    }

    public var id: Int
    public var name: String
    public var englishName: String?
    public var japaneseName: String?
    public var anilistId: Int?
    public var flags: Flags?

    enum CodingKeys: String, CodingKey {
        case id, name, flags
        case englishName = "english_name", japaneseName = "japanese_name", anilistId = "anilist_id"
    }
}

/// One file in an entry: a subtitle, or an archive of them.
public struct JimakuFile: Decodable, Hashable, Sendable, Identifiable {
    public var name: String
    public var url: URL
    public var size: Int?

    public var id: URL { url }

    public init(name: String, url: URL, size: Int?) {
        self.name = name
        self.url = url
        self.size = size
    }
}

/// Jimaku's API (`/api/openapi.json`). Every request needs the user's API key (free
/// account, jimaku.cc → Account) in the `Authorization` header.
public struct JimakuClient: Sendable {
    /// Jimaku itself, not a self-hosted server.
    public static let baseURL = URL(string: "https://jimaku.cc")!
    /// Jimaku asks clients to identify themselves.
    public static let userAgent = "Miru/0.1 (Amatsubame; https://amatsubame.com)"

    let apiKey: String
    let http: HTTPClient
    let baseURL: URL

    public init(apiKey: String, http: HTTPClient = HTTPClient(), baseURL: URL = JimakuClient.baseURL) {
        self.apiKey = apiKey
        self.http = http
        self.baseURL = baseURL
    }

    /// Anime entries for an AniList id (usually one per season).
    public func search(anilistId: Int) async throws(ConnectionError) -> [JimakuEntry] {
        try await get([JimakuEntry].self, "api/entries/search", ["anime": "true", "anilist_id": String(anilistId)])
    }

    /// Anime entries whose names match `query`.
    public func search(query: String) async throws(ConnectionError) -> [JimakuEntry] {
        try await get([JimakuEntry].self, "api/entries/search", ["anime": "true", "query": query])
    }

    /// An entry's files, only those for `episode` when given (Jimaku matches it from the names).
    public func files(entryId: Int, episode: Int? = nil) async throws(ConnectionError) -> [JimakuFile] {
        try await get([JimakuFile].self, "api/entries/\(entryId)/files", ["episode": episode.map(String.init)])
    }

    /// A file's contents.
    public func download(_ file: JimakuFile) async throws(ConnectionError) -> Data {
        try await http.send(authorize(URLRequest(url: file.url))).data
    }

    private func get<T: Decodable>(_ type: T.Type, _ path: String, _ query: [String: String?]) async throws(ConnectionError) -> T {
        let items = query.compactMap { key, value in value.map { URLQueryItem(name: key, value: $0) } }.sorted { $0.name < $1.name }
        let url = baseURL.appending(path: path).appending(queryItems: items)
        return try await http.decode(type, from: authorize(URLRequest(url: url)))
    }

    private func authorize(_ request: URLRequest) -> URLRequest {
        var request = request
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }
}

/// Finds a show's AniList id from its AniDB id (Jellyfin's Shoko plugin only knows AniDB),
/// through the public arm.haglund.dev mapping service. Only the AniDB number is sent.
public struct AnimeIdMapper: Sendable {
    public static let baseURL = URL(string: "https://arm.haglund.dev")!

    struct Ids: Decodable {
        var anilist: Int?
    }

    let http: HTTPClient
    let baseURL: URL

    public init(http: HTTPClient = HTTPClient(), baseURL: URL = AnimeIdMapper.baseURL) {
        self.http = http
        self.baseURL = baseURL
    }

    /// Nil when the service doesn't know the show (it answers `null` or `{}`).
    public func anilistId(anidbId: Int) async throws(ConnectionError) -> Int? {
        var request = URLRequest(url: baseURL.appending(path: "api/v2/ids")
            .appending(queryItems: [URLQueryItem(name: "source", value: "anidb"), URLQueryItem(name: "id", value: String(anidbId))]))
        request.setValue(JimakuClient.userAgent, forHTTPHeaderField: "User-Agent")
        let data = try await http.send(request).data
        return (try? JSONDecoder().decode(Ids?.self, from: data))??.anilist
    }
}
