import Core
import Foundation

/// Spaces one service's requests and waits out its 429s (AniList: 30 a minute for now, with a
/// minute's timeout when it's exceeded; MangaBaka: `Retry-After: 10`). Shared by every client of
/// the service in the app.
public actor RequestLimiter {
    public static let userAgent = "Amatsubame (+https://amatsubame.com)"
    /// AniList's degraded limit (30 a minute): a request every 2 s.
    public static let aniList = RequestLimiter(spacing: .seconds(2))
    public static let mangaBaka = RequestLimiter(spacing: .milliseconds(400))

    let spacing: Duration
    /// How many 429s in a row are waited out before giving up.
    let retries: Int
    private let clock: any Clock<Duration>
    private var next: ContinuousClock.Instant?
    private let sleep: @Sendable (Duration) async throws -> Void

    public init(spacing: Duration, retries: Int = 2, sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.spacing = spacing
        self.retries = retries
        self.clock = ContinuousClock()
        self.sleep = sleep
    }

    /// Sends the request when the spacing allows, again after a 429's `Retry-After`.
    public func send(_ request: URLRequest, with http: HTTPClient) async throws(ConnectionError) -> HTTPResponse {
        var attempt = 0
        while true {
            try await waitTurn()
            let response = try await http.sendRaw(request)
            guard response.response.statusCode == 429, attempt < retries else { return response }
            attempt += 1
            let seconds = response.response.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? 60
            next = ContinuousClock.now + .seconds(min(max(seconds, 1), 120))
        }
    }

    private func waitTurn() async throws(ConnectionError) {
        let now = ContinuousClock.now
        let start = max(now, next ?? now)
        next = start + spacing
        guard start > now else { return }
        do {
            try await sleep(start - now)
        } catch {
            throw .cancelled
        }
    }
}
