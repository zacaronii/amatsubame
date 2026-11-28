import Core
import Foundation

// Verified against Kavita 0.9.1.23 (2026-11-22) with a test account: `POST /api/want-to-read/v2`
// (paged, a series filter body) lists the series; `GET /api/want-to-read?seriesId=` is true or
// false; `POST add-series` and `remove-series` take `{seriesIds}` and answer 200 also when there's
// nothing to change. The list route is in Kavita 0.7.8 and later (add, remove and the check in
// 0.7.5 already); older servers answer it 404.

extension KavitaClient {
    /// One page of the Want to Read list.
    public func wantToReadPage(_ page: Int, pageSize: Int) async throws(ConnectionError) -> KavitaPage<(KavitaSeries, raw: Data)> {
        let request = try jsonRequest("POST", "api/want-to-read/v2", query: [
            URLQueryItem(name: "pageNumber", value: String(page)),
            URLQueryItem(name: "pageSize", value: String(pageSize)),
        ], body: SeriesFilter())
        return try await paged(request)
    }

    /// The whole Want to Read list, page by page, in Kavita's order.
    public func wantToRead(pageSize: Int = 100) async throws(ConnectionError) -> [(KavitaSeries, raw: Data)] {
        var all: [(KavitaSeries, raw: Data)] = []
        var page = 1
        while true {
            let result = try await wantToReadPage(page, pageSize: pageSize)
            all += result.items
            // Without the Pagination header, a short page is the last.
            guard result.pagination.map({ $0.currentPage < $0.totalPages }) ?? (result.items.count == pageSize), page < 200 else { return all }
            page += 1
        }
    }

    public func isWantToRead(seriesId: Int) async throws(ConnectionError) -> Bool {
        try await http.decode(Bool.self, from: request("api/want-to-read", query: [URLQueryItem(name: "seriesId", value: String(seriesId))]))
    }

    /// Call only from the outbox handler.
    public func setWantToRead(_ wanted: Bool, seriesIds: [Int]) async throws(ConnectionError) {
        _ = try await http.send(jsonRequest("POST", wanted ? "api/want-to-read/add-series" : "api/want-to-read/remove-series",
                                            body: ["seriesIds": seriesIds]))
    }
}

/// Sends one series' Want to Read toggle (`WantToReadRow`), as it is when the job runs.
public struct KavitaWantToReadHandler: OutboxHandler {
    public let kind = OutboxJobKind.kavitaWantToRead
    let store: WantToReadStore
    let features: ReaderMarkStore
    let account: @Sendable () -> String?
    let makeClient: @Sendable () throws -> KavitaClient?

    public init(store: WantToReadStore, features: ReaderMarkStore, account: @escaping @Sendable () -> String? = { nil },
                makeClient: @escaping @Sendable () throws -> KavitaClient?) {
        self.store = store
        self.features = features
        self.account = account
        self.makeClient = makeClient
    }

    public func send(_ job: OutboxJob, media: [(field: String, url: URL)]) async throws {
        let payload: WantToReadJob
        do {
            payload = try job.decodePayload(WantToReadJob.self)
        } catch {
            throw OutboxPermanentFailure("Unreadable Want to Read job: \(error.localizedDescription)")
        }
        // Only a toggle still to be sent (a job run again after the app died mid-way finds its
        // row settled, and sends nothing).
        guard let row = try store.row(account: payload.account, seriesId: payload.seriesId),
              row.state == .pendingAdd || row.state == .pendingRemove else { return }
        guard let client = try makeClient() else { throw ConnectionError.message("Kavita isn't set up.") }
        // Toggled while signed in to another Kavita account: it waits for that one.
        if let current = account(), current != row.account {
            throw ConnectionError.message("This belongs to another Kavita account.")
        }
        do {
            try await client.setWantToRead(row.isWanted, seriesIds: [row.seriesId])
        } catch {
            switch error {
            case .server(status: 404):
                // Before Kavita 0.7.5 there's no Want to Read; only its list's own 404 decides it.
                do {
                    _ = try await client.wantToReadPage(1, pageSize: 1)
                } catch .server(status: 404) {
                    try features.setAvailable(false, .wantToRead, account: row.account)
                    try store.dropUnsent(account: row.account)
                    return
                }
                throw OutboxPermanentFailure("Kavita couldn't find the series (HTTP 404).")
            case .server(let status) where (400..<500).contains(status) && status != 408 && status != 429:
                throw OutboxPermanentFailure("Kavita refused the Want to Read change (HTTP \(status)).")
            default:
                throw error
            }
        }
        try store.didSend(row)
    }
}

/// Fetches the account's Want to Read from Kavita and brings the device's copy up to date.
public struct KavitaWantToReadSync: Sendable {
    let client: KavitaClient
    let store: WantToReadStore
    let features: ReaderMarkStore
    let account: String

    public init(client: KavitaClient, store: WantToReadStore, features: ReaderMarkStore, account: String) {
        self.client = client
        self.store = store
        self.features = features
        self.account = account
    }

    /// The whole list. Returns its series (to cache for the shelf), or nil when the server has no
    /// Want to Read.
    @discardableResult
    public func refresh() async throws -> [(KavitaSeries, raw: Data)]? {
        let listed: [(KavitaSeries, raw: Data)]
        // Toggles Kavita takes while the list is on its way stay as they are.
        let listedAt = Date()
        do {
            listed = try await client.wantToRead()
        } catch ConnectionError.server(status: 404) {
            try features.setAvailable(false, .wantToRead, account: account)
            try store.dropUnsent(account: account)
            return nil
        }
        try features.setAvailable(true, .wantToRead, account: account)
        try store.merge(listed.map(\.0.id), account: account, listedAt: listedAt)
        return listed
    }

    /// One series (the series page, when it opens).
    public func check(seriesId: Int) async throws {
        let askedAt = Date()
        try store.note(try await client.isWantToRead(seriesId: seriesId), seriesId: seriesId, account: account, askedAt: askedAt)
    }
}
