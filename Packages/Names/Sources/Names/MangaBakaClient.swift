import Core
import Foundation

/// MangaBaka (mangabaka.org): from a manga or light novel's title to its AniList and
/// MyAnimeList ids, when Kavita has neither. Its own data is CC BY-NC-SA 4.0 (credited in About).
public struct MangaBakaClient: Sendable {
    public static let base = URL(string: "https://api.mangabaka.org")!

    public enum Kind: String, Sendable {
        case manga
        case novel
    }

    /// One matching series and the ids it links to.
    public struct Series: Equatable, Sendable {
        public var id: Int
        public var title: String
        public var aniListId: Int?
        public var malId: Int?
    }

    let http: HTTPClient
    let limiter: RequestLimiter

    public init(http: HTTPClient, limiter: RequestLimiter = .mangaBaka) {
        self.http = http
        self.limiter = limiter
    }

    /// Series whose title matches exactly (MangaBaka's match returns nothing rather than guess).
    public func match(_ title: String, kind: Kind?) async throws(ConnectionError) -> [Series] {
        var components = URLComponents(url: Self.base.appending(path: "v2/series/match"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "q", value: title), URLQueryItem(name: "limit", value: "10")]
            + (kind.map { [URLQueryItem(name: "type", value: $0.rawValue)] } ?? [])
        var request = URLRequest(url: components.url!)
        request.setValue(RequestLimiter.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let response = try await limiter.send(request, with: http)
        guard (200..<300).contains(response.response.statusCode) else { throw .server(status: response.response.statusCode) }
        do {
            return try JSONDecoder().decode(Response.self, from: response.data).data.map(\.series)
        } catch {
            throw .unexpectedResponse(String(describing: error))
        }
    }

    struct Response: Decodable {
        struct Item: Decodable {
            struct Source: Decodable {
                struct Link: Decodable { var id: Int? }
                var anilist: Link?
                var my_anime_list: Link?
            }
            struct Title: Decodable {
                var language: String?
                var title: String?
            }
            var id: Int
            var titles: [Title]?
            var source: Source?

            /// The Japanese title, else the English one, else any.
            var series: Series {
                let titles = titles ?? []
                let title = (titles.first { $0.language == "ja" } ?? titles.first { $0.language == "en" } ?? titles.first)?.title
                return Series(id: id, title: title ?? "", aniListId: source?.anilist?.id, malId: source?.my_anime_list?.id)
            }
        }
        var data: [Item]
    }
}
