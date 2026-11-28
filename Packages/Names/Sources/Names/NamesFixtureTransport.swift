#if DEBUG
import Core
import Foundation

/// UI tests (`UITEST_NAMES_FIXTURES=<folder>`): AniList, MangaBaka and the portraits answered
/// from a folder of made-up responses (`anilist-cast.json`, `anilist-search.json`,
/// `mangabaka-match.json`, `portrait.png`), so no test reaches the real services.
public struct NamesFixtureTransport: HTTPTransport {
    let folder: URL

    public init(folder: URL) {
        self.folder = folder
    }

    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let name: String
        switch request.url?.host() {
        case "graphql.anilist.co":
            let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            name = body.contains("characters(") ? "anilist-cast.json" : body.contains("Page(") ? "anilist-search.json" : "anilist-media.json"
        case "api.mangabaka.org": name = "mangabaka-match.json"
        default: name = "portrait.png"
        }
        let data = (try? Data(contentsOf: folder.appending(path: name))) ?? Data()
        let response = HTTPURLResponse(url: request.url!, statusCode: data.isEmpty ? 404 : 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        return (data, response)
    }
}
#endif
