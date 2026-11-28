import Core
import Foundation

/// AniList's media: a manga (light novels too) or an anime.
public enum AniListMediaType: String, Codable, Sendable {
    case manga = "MANGA"
    case anime = "ANIME"
}

/// One AniList media, as a title search or an id lookup returns it.
public struct AniListMedia: Codable, Equatable, Identifiable, Sendable {
    public struct Title: Codable, Equatable, Sendable {
        public var native: String?
        public var romaji: String?
        public var english: String?

        public init(native: String? = nil, romaji: String? = nil, english: String? = nil) {
            self.native = native
            self.romaji = romaji
            self.english = english
        }
    }

    public var id: Int
    public var idMal: Int?
    public var type: AniListMediaType?
    /// TV, MOVIE, OVA, ONA, MANGA, NOVEL, ONE_SHOT…
    public var format: String?
    public var seasonYear: Int?
    public var startYear: Int?
    public var episodes: Int?
    public var title: Title
    public var synonyms: [String]
    public var cover: URL?

    public init(id: Int, idMal: Int? = nil, type: AniListMediaType? = nil, format: String? = nil, seasonYear: Int? = nil,
                startYear: Int? = nil, episodes: Int? = nil, title: Title, synonyms: [String] = [], cover: URL? = nil) {
        self.id = id
        self.idMal = idMal
        self.type = type
        self.format = format
        self.seasonYear = seasonYear
        self.startYear = startYear
        self.episodes = episodes
        self.title = title
        self.synonyms = synonyms
        self.cover = cover
    }

    /// The title to show: Japanese first.
    public var displayTitle: String { title.native ?? title.romaji ?? title.english ?? "AniList \(id)" }
    /// Every title it goes by.
    public var allTitles: [String] { [title.native, title.romaji, title.english].compactMap(\.self) + synonyms }
}

/// One character of a cast (no description: spoilers).
public struct AniListCharacter: Codable, Equatable, Identifiable, Sendable {
    public enum Role: String, Codable, Sendable {
        case main = "MAIN"
        case supporting = "SUPPORTING"
        case background = "BACKGROUND"
    }

    public var id: Int
    public var role: Role
    /// The Japanese name, as AniList writes it (kanji, kana, sometimes with a space or ・).
    public var native: String?
    /// Western order ("Hitori Gotou").
    public var full: String?
    /// The given name in romaji.
    public var first: String?
    /// The family name in romaji.
    public var last: String?
    public var alternative: [String]
    public var image: URL?

    public init(id: Int, role: Role, native: String?, full: String? = nil, first: String? = nil, last: String? = nil,
                alternative: [String] = [], image: URL? = nil) {
        self.id = id
        self.role = role
        self.native = native
        self.full = full
        self.first = first
        self.last = last
        self.alternative = alternative
        self.image = image
    }
}

/// AniList's GraphQL API, for casts and finding a series' media. No account: public data only.
/// The API allows 30 requests a minute at the moment (90 when it isn't degraded); `limiter`
/// spaces requests and waits out a 429.
public struct AniListClient: Sendable {
    public static let endpoint = URL(string: "https://graphql.anilist.co")!
    /// The most pages of a cast fetched (25 a page): a long series' main and supporting cast.
    public static let maxCastPages = 8

    let http: HTTPClient
    let limiter: RequestLimiter

    public init(http: HTTPClient, limiter: RequestLimiter = .aniList) {
        self.http = http
        self.limiter = limiter
    }

    /// The main and supporting characters, main first.
    public func cast(mediaId: Int, type: AniListMediaType) async throws(ConnectionError) -> (media: AniListMedia, characters: [AniListCharacter]) {
        var characters: [AniListCharacter] = []
        var media: AniListMedia?
        for page in 1...Self.maxCastPages {
            let data: CastResponse = try await query(Self.castQuery, variables: ["id": .int(mediaId), "type": .string(type.rawValue), "page": .int(page)])
            guard let found = data.Media else { throw .unexpectedResponse("AniList has no media \(mediaId)") }
            media = media ?? found.media
            let edges = found.characters?.edges ?? []
            var reachedBackground = false
            for edge in edges {
                guard let node = edge.node, let role = AniListCharacter.Role(rawValue: edge.role ?? "") else { continue }
                if role == .background {
                    reachedBackground = true
                    continue
                }
                characters.append(AniListCharacter(
                    id: node.id, role: role, native: node.name?.native?.trimmingCharacters(in: .whitespaces).nilIfEmpty,
                    full: node.name?.full, first: node.name?.first, last: node.name?.last,
                    alternative: node.name?.alternative?.compactMap(\.self) ?? [], image: node.image?.medium.flatMap(URL.init(string:))
                ))
            }
            // Sorted by role, so background characters come last.
            guard found.characters?.pageInfo?.hasNextPage == true, !reachedBackground, !edges.isEmpty else { break }
        }
        return (media!, characters)
    }

    /// The media for a MyAnimeList id.
    public func media(malId: Int, type: AniListMediaType) async throws(ConnectionError) -> AniListMedia? {
        let data: MediaResponse = try await query(Self.malQuery, variables: ["idMal": .int(malId), "type": .string(type.rawValue)])
        return data.Media?.media
    }

    /// Media whose titles match, best first.
    public func search(_ title: String, type: AniListMediaType) async throws(ConnectionError) -> [AniListMedia] {
        let data: SearchResponse = try await query(Self.searchQuery, variables: ["search": .string(title), "type": .string(type.rawValue)])
        return data.Page?.media?.map(\.media) ?? []
    }

    // MARK: Requests

    enum Variable: Encodable {
        case int(Int)
        case string(String)

        func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .int(let value): try container.encode(value)
            case .string(let value): try container.encode(value)
            }
        }
    }

    struct Body: Encodable {
        var query: String
        var variables: [String: Variable]
    }

    struct Envelope<T: Decodable>: Decodable {
        struct Message: Decodable { var message: String? }
        var data: T?
        var errors: [Message]?
    }

    func query<T: Decodable>(_ query: String, variables: [String: Variable]) async throws(ConnectionError) -> T {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Cloudflare in front of AniList turns away anonymous clients.
        request.setValue(RequestLimiter.userAgent, forHTTPHeaderField: "User-Agent")
        do {
            request.httpBody = try JSONEncoder().encode(Body(query: query, variables: variables))
        } catch {
            throw .message(error.localizedDescription)
        }
        let response = try await limiter.send(request, with: http)
        guard (200..<300).contains(response.response.statusCode) else {
            let message = (try? JSONDecoder().decode(Envelope<T>.self, from: response.data))?.errors?.first?.message
            if response.response.statusCode == 404 { throw .unexpectedResponse(message ?? "Not found") }
            throw .server(status: response.response.statusCode)
        }
        do {
            let envelope = try JSONDecoder().decode(Envelope<T>.self, from: response.data)
            guard let data = envelope.data else { throw ConnectionError.unexpectedResponse(envelope.errors?.first?.message ?? "No data") }
            return data
        } catch let error as ConnectionError {
            throw error
        } catch {
            throw .unexpectedResponse(String(describing: error))
        }
    }

    static let mediaFields = "id idMal type format seasonYear startDate { year } episodes title { native romaji english } synonyms coverImage { medium }"

    static let castQuery = """
    query ($id: Int, $type: MediaType, $page: Int) { Media(id: $id, type: $type) { \(mediaFields)
      characters(page: $page, perPage: 25, sort: [ROLE, RELEVANCE, ID]) { pageInfo { hasNextPage }
        edges { role node { id name { native full first last alternative } image { medium } } } } } }
    """

    static let malQuery = "query ($idMal: Int, $type: MediaType) { Media(idMal: $idMal, type: $type) { \(mediaFields) } }"

    static let searchQuery = """
    query ($search: String, $type: MediaType) { Page(perPage: 10) {
      media(search: $search, type: $type, sort: [SEARCH_MATCH, POPULARITY_DESC]) { \(mediaFields) } } }
    """

    // MARK: Responses

    struct MediaNode: Decodable {
        struct Year: Decodable { var year: Int? }
        struct Cover: Decodable { var medium: String? }
        var id: Int
        var idMal: Int?
        var type: AniListMediaType?
        var format: String?
        var seasonYear: Int?
        var startDate: Year?
        var episodes: Int?
        var title: AniListMedia.Title?
        var synonyms: [String?]?
        var coverImage: Cover?
        var characters: Characters?

        var media: AniListMedia {
            AniListMedia(id: id, idMal: idMal, type: type, format: format, seasonYear: seasonYear, startYear: startDate?.year,
                         episodes: episodes, title: title ?? AniListMedia.Title(), synonyms: synonyms?.compactMap(\.self) ?? [],
                         cover: coverImage?.medium.flatMap(URL.init(string:)))
        }
    }

    struct Characters: Decodable {
        struct PageInfo: Decodable { var hasNextPage: Bool? }
        struct Edge: Decodable {
            struct Node: Decodable {
                struct Name: Decodable {
                    var native: String?
                    var full: String?
                    var first: String?
                    var last: String?
                    var alternative: [String?]?
                }
                struct Image: Decodable { var medium: String? }
                var id: Int
                var name: Name?
                var image: Image?
            }
            var role: String?
            var node: Node?
        }
        var pageInfo: PageInfo?
        var edges: [Edge]?
    }

    struct CastResponse: Decodable { var Media: MediaNode? }
    struct MediaResponse: Decodable { var Media: MediaNode? }
    struct SearchResponse: Decodable {
        struct Page: Decodable { var media: [MediaNode]? }
        var Page: Page?
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
