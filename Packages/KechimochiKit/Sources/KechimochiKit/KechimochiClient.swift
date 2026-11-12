import Core
import Foundation

/// kechimochi's web API, read only. It has no login: anyone who can reach it can also change
/// or wipe it (`/api/reset`, imports, deletes), so keep it on a private network. This client
/// can only make the requests in `allowedPaths`: the version (GET) and the dashboard reads,
/// which are POSTs only because they carry date bounds (verified on kechimochi 0.3.3: they don't write).
public struct KechimochiClient: Sendable {
    public let baseURL: URL
    let http: HTTPClient

    /// Every path this client may use.
    public static let allowedPaths: Set<String> = ["/api/version", "/api/dashboard/snapshot", "/api/dashboard/heatmap-year"]

    public init(baseURL: URL, http: HTTPClient = HTTPClient()) {
        self.baseURL = baseURL
        self.http = http
    }

    /// "web-0.3.3".
    public func version() async throws(ConnectionError) -> String {
        try await http.decode(String.self, from: .get(try url("/api/version")))
    }

    /// The summary and `today`'s year of the heatmap (`today` in the user's calendar, "2026-11-07").
    public func snapshot(today: String, year: Int) async throws(ConnectionError) -> KechimochiSnapshot {
        struct Request: Encodable {
            var request_id = 1
            var today: String
            var heatmap_year: Int
            var recent_offset = 0
            var recent_limit = 1
        }
        return try await post("/api/dashboard/snapshot", Request(today: today, heatmap_year: year), as: KechimochiSnapshot.self)
    }

    /// Another year's heatmap (the year menu).
    public func heatmap(year: Int) async throws(ConnectionError) -> KechimochiHeatmap {
        struct Request: Encodable {
            var request_id = 1
            var year: Int
        }
        return try await post("/api/dashboard/heatmap-year", Request(year: year), as: KechimochiHeatmap.self)
    }

    private func post<T: Decodable>(_ path: String, _ body: some Encodable, as type: T.Type) async throws(ConnectionError) -> T {
        let request: URLRequest
        do {
            request = try .json("POST", try url(path), body: body)
        } catch let error as ConnectionError {
            throw error
        } catch {
            throw .message(error.localizedDescription)
        }
        return try await http.decode(T.self, from: request)
    }

    private func url(_ path: String) throws(ConnectionError) -> URL {
        guard Self.allowedPaths.contains(path) else { throw .message("kechimochi: \(path) isn't a read") }
        return baseURL.appending(path: String(path.dropFirst()))
    }
}
