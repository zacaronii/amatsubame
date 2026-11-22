import Core
import Foundation

// Verified against Kavita 0.9.1.23 (2026-11-22) with a test account; made, filled, emptied and
// checked gone each time:
// - `GET /api/Collection?ownedOnly=` lists collections (own, and promoted ones of others):
//   id, title, owner (username), promoted, source (0 Kavita; 1 AniList, 2 MAL, 4 CBR,
//   5 Hardcover, 6 MangaBaka are synced from outside), itemCount. In Kavita 0.8.0 and later.
// - `POST update-for-series {collectionTagId, collectionTagTitle, seriesIds}` adds series to a
//   collection; with id 0 it makes one. Making one with series in the same request fails on this
//   nightly (500), so a new collection is made empty, then filled. It answers no id, doesn't refuse
//   a title already used (Kavita's web UI asks `name-exists` first), and 400s for an id that's
//   gone. Adding a series already in it is a 200.
// - `POST update-series {tag, seriesIdsToRemove}` takes series out; taking out the last one deletes
//   the collection. `POST delete-multiple {collectionIds}` deletes.
// - A collection's series: `POST /api/Series/v2` with field 7; `GET all-series?seriesId&ownedOnly`
//   the collections a series is in.
// - Kavita's cleanup task removes collections with no series (in 0.8.0, 0.9.1.4 and the nightly).

/// A collection as Kavita lists it.
public struct KavitaCollection: Decodable, Equatable, Sendable {
    public var id: Int
    public var title: String
    public var promoted: Bool?
    public var owner: String?
    public var source: Int?
    public var itemCount: Int?

    func listed(username: String?) -> CollectionStore.Listed {
        CollectionStore.Listed(serverId: id, title: title, isOwn: username.map { $0.caseInsensitiveCompare(owner ?? "") == .orderedSame } ?? false,
                               owner: owner, promoted: promoted ?? false, source: source ?? 0, itemCount: itemCount ?? 0)
    }
}

extension KavitaClient {
    public func collections(ownedOnly: Bool) async throws(ConnectionError) -> [(KavitaCollection, raw: Data)] {
        let response = try await http.send(request("api/Collection", query: [URLQueryItem(name: "ownedOnly", value: String(ownedOnly))]))
        do {
            return try KavitaJSON.decodeEach(KavitaCollection.self, from: response.data).map { ($0.0, raw: $0.1) }
        } catch {
            throw .unexpectedResponse(String(describing: error))
        }
    }

    /// The own collections a series is in.
    public func collections(ofSeries seriesId: Int) async throws(ConnectionError) -> [KavitaCollection] {
        try await http.decode([KavitaCollection].self, from: request("api/Collection/all-series", query: [
            URLQueryItem(name: "seriesId", value: String(seriesId)), URLQueryItem(name: "ownedOnly", value: "true"),
        ]), decoder: KavitaJSON.decoder)
    }

    /// A collection's series, every page.
    public func series(inCollection collectionId: Int, pageSize: Int = 100) async throws(ConnectionError) -> [(KavitaSeries, raw: Data)] {
        var all: [(KavitaSeries, raw: Data)] = []
        var page = 1
        while true {
            let request = try jsonRequest("POST", "api/Series/v2", query: [
                URLQueryItem(name: "pageNumber", value: String(page)), URLQueryItem(name: "pageSize", value: String(pageSize)),
            ], body: SeriesFilter(collectionId: collectionId))
            let result: KavitaPage<(KavitaSeries, raw: Data)> = try await paged(request)
            all += result.items
            guard result.pagination.map({ $0.currentPage < $0.totalPages }) ?? (result.items.count == pageSize), page < 200 else { return all }
            page += 1
        }
    }

    // MARK: Writes (call only from the outbox handler)

    struct BulkAdd: Encodable {
        var collectionTagId: Int
        var collectionTagTitle: String
        var seriesIds: [Int]
    }

    /// Makes an empty collection (Kavita answers no id: list the own ones to find it).
    public func createCollection(title: String) async throws(ConnectionError) {
        _ = try await http.send(jsonRequest("POST", "api/Collection/update-for-series", body: BulkAdd(collectionTagId: 0, collectionTagTitle: title, seriesIds: [])))
    }

    public func addToCollection(_ collectionId: Int, title: String, seriesIds: [Int]) async throws(ConnectionError) {
        _ = try await http.send(jsonRequest("POST", "api/Collection/update-for-series",
                                            body: BulkAdd(collectionTagId: collectionId, collectionTagTitle: title, seriesIds: seriesIds)))
    }

    /// `tag`: the collection as Kavita listed it (the route takes it whole).
    public func removeFromCollection(tag: Data, seriesIds: [Int]) async throws(ConnectionError) {
        guard let object = try? JSONSerialization.jsonObject(with: tag),
              let body = try? JSONSerialization.data(withJSONObject: ["tag": object, "seriesIdsToRemove": seriesIds]) else {
            throw .unexpectedResponse("Couldn't read the collection")
        }
        var request = request("api/Collection/update-series")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        _ = try await http.send(request)
    }

    public func deleteCollection(_ collectionId: Int) async throws(ConnectionError) {
        _ = try await http.send(jsonRequest("POST", "api/Collection/delete-multiple", body: ["collectionIds": [collectionId]]))
    }
}

/// Sends one collection's create or delete, or one series' add or remove, as its rows are when
/// the job runs.
public struct KavitaCollectionHandler: OutboxHandler {
    public let kind = OutboxJobKind.kavitaCollection
    let store: CollectionStore
    let features: ReaderMarkStore
    let outbox: OutboxStore
    let account: @Sendable () -> String?
    let makeClient: @Sendable () throws -> KavitaClient?

    public init(store: CollectionStore, features: ReaderMarkStore, outbox: OutboxStore, account: @escaping @Sendable () -> String? = { nil },
                makeClient: @escaping @Sendable () throws -> KavitaClient?) {
        self.store = store
        self.features = features
        self.outbox = outbox
        self.account = account
        self.makeClient = makeClient
    }

    public func send(_ job: OutboxJob, media: [(field: String, url: URL)]) async throws {
        let payload: CollectionJob
        do {
            payload = try job.decodePayload(CollectionJob.self)
        } catch {
            throw OutboxPermanentFailure("Unreadable collection job: \(error.localizedDescription)")
        }
        // Gone (deleted here, or dropped): nothing to send.
        guard let collection = try store.collection(payload.collectionId) else { return }
        guard let client = try makeClient() else { throw ConnectionError.message("Kavita isn't set up.") }
        if let current = account(), current != collection.account {
            throw ConnectionError.message("This belongs to another Kavita account.")
        }
        do {
            if let seriesId = payload.seriesId {
                try await sendSeries(seriesId, of: collection, client)
            } else {
                switch collection.state {
                case .pendingCreate: try await create(collection, client)
                case .pendingDelete: try await delete(collection, client)
                case .synced: return
                }
            }
        } catch let error as ConnectionError {
            try await settle(error, collection: collection, client: client)
        }
    }

    // MARK: The collection

    /// Safe to run twice: a collection with the title that this device doesn't know yet is taken
    /// as the one it made (the answer to an earlier try may have been lost).
    private func create(_ collection: CollectionRow, _ client: KavitaClient) async throws {
        guard let id = collection.id else { return }
        if let found = try await made(collection, client) {
            try store.didCreate(id, serverId: found)
            return
        }
        do {
            try await client.createCollection(title: collection.title)
        } catch .server(let status) where (400..<500).contains(status) && status != 404 && status != 408 && status != 429 {
            try store.dropCollection(id)
            throw OutboxPermanentFailure("Kavita couldn't make the collection \u{201C}\(collection.title)\u{201D} (HTTP \(status)).")
        } catch .server(status: 500) {
            // Kavita failing on the request itself (as this nightly does for a collection made
            // with series); 502–504 are outages and are tried again.
            let status = 500
            try store.dropCollection(id)
            throw OutboxPermanentFailure("Kavita couldn't make the collection \u{201C}\(collection.title)\u{201D} (HTTP \(status)).")
        }
        guard let found = try await made(collection, client) else {
            throw ConnectionError.message("Kavita hasn't listed the new collection yet.")
        }
        // Deleted here while this create was on its way: what it just made goes too (never one
        // it only adopted).
        if try !store.didCreate(id, serverId: found) {
            try await client.deleteCollection(found)
        }
    }

    /// An own collection with the title (as Kavita compares titles) this device doesn't know yet.
    private func made(_ collection: CollectionRow, _ client: KavitaClient) async throws -> Int? {
        let known = try store.knownServerIds(account: collection.account)
        let title = CollectionRow.normalized(collection.title)
        return try await client.collections(ownedOnly: true).map(\.0)
            .filter { CollectionRow.normalized($0.title) == title && !known.contains($0.id) }
            .map(\.id).max()
    }

    private func delete(_ collection: CollectionRow, _ client: KavitaClient) async throws {
        guard let id = collection.id, let serverId = collection.serverId else { return }
        do {
            try await client.deleteCollection(serverId)
        } catch .server(status: 400) {
            // Already gone is deleted.
            guard try await !client.collections(ownedOnly: true).contains(where: { $0.0.id == serverId }) else { throw ConnectionError.server(status: 400) }
        }
        try store.didDelete(id)
    }

    // MARK: Its series

    private func sendSeries(_ seriesId: Int, of collection: CollectionRow, _ client: KavitaClient) async throws {
        guard let id = collection.id, let row = try store.seriesRow(collectionId: id, seriesId: seriesId),
              row.state == .pendingAdd || row.state == .pendingRemove else { return }
        guard collection.state != .pendingDelete else {
            try store.dropSeries(row)
            return
        }
        guard let serverId = collection.serverId else {
            // Waits for its collection to be made; with no create to wait for, it can't go anywhere.
            if collection.state == .pendingCreate, try store.isQueued(CollectionJob(account: collection.account, collectionId: id)) {
                throw ConnectionError.message("Waiting for the collection \u{201C}\(collection.title)\u{201D} to be made.")
            }
            try store.dropSeries(row)
            return
        }
        if row.state == .pendingAdd {
            try await add([row], to: collection, serverId: serverId, client)
            return
        }
        // Adds before removes in the same collection: taking out what looks like the last series
        // would delete a collection that's about to get another.
        let adds = try store.pendingSeries(collectionId: id).filter { $0.state == .pendingAdd }
        if !adds.isEmpty { try await add(adds, to: collection, serverId: serverId, client) }
        guard let tag = try await client.collections(ownedOnly: true).first(where: { $0.0.id == serverId })?.raw else {
            // Not there any more: nothing to take it out of, and the collection goes here too.
            try store.dropCollection(id)
            return
        }
        try await client.removeFromCollection(tag: tag, seriesIds: [seriesId])
        try store.didSend(row)
        // Kavita deletes a collection when its last series goes: when the count here says so (or
        // can't tell), one look, and a collection gone goes here too.
        if (try store.seriesCount(collectionId: id)).map({ $0 == 0 }) ?? true,
           try await !client.collections(ownedOnly: true).contains(where: { $0.0.id == serverId }) {
            try store.dropCollection(id)
        }
    }

    private func add(_ rows: [CollectionSeriesRow], to collection: CollectionRow, serverId: Int, _ client: KavitaClient) async throws {
        guard let id = collection.id else { return }
        do {
            try await client.addToCollection(serverId, title: collection.title, seriesIds: rows.map(\.seriesId))
        } catch .server(status: 400) {
            guard try await !client.collections(ownedOnly: true).contains(where: { $0.0.id == serverId }) else {
                throw OutboxPermanentFailure("Kavita refused to add to \u{201C}\(collection.title)\u{201D} (HTTP 400).")
            }
            if collection.confirmed {
                // Deleted on another device: it goes here too, with the adds and their jobs.
                try store.dropCollection(id)
                return
            }
            // Made here and cleaned up empty by Kavita before its first series: made again.
            if try store.recreate(id, outbox: outbox) {
                throw ConnectionError.message("Kavita removed the empty collection \u{201C}\(collection.title)\u{201D}; making it again.")
            }
            try store.dropCollection(id)
            throw OutboxPermanentFailure("Kavita didn't keep the collection \u{201C}\(collection.title)\u{201D}.")
        }
        for row in rows { try store.didSend(row) }
    }

    // MARK: When the server says no

    private func settle(_ error: ConnectionError, collection: CollectionRow, client: KavitaClient) async throws {
        switch error {
        case .server(status: 404):
            // Before Kavita 0.8.0; only the list's own 404 decides it.
            do {
                _ = try await client.collections(ownedOnly: true)
            } catch .server(status: 404) {
                try features.setAvailable(false, .collections, account: collection.account)
                if let id = collection.id, collection.state == .pendingCreate { try store.dropCollection(id) }
                return
            }
            throw OutboxPermanentFailure("Kavita couldn't find the collection \u{201C}\(collection.title)\u{201D} (HTTP 404).")
        case .server(let status) where (400..<500).contains(status) && status != 408 && status != 429:
            throw OutboxPermanentFailure("Kavita refused the change to \u{201C}\(collection.title)\u{201D} (HTTP \(status)).")
        default:
            throw error
        }
    }
}

/// Fetches collections from Kavita and brings the device's copy up to date.
public struct KavitaCollectionSync: Sendable {
    let client: KavitaClient
    let store: CollectionStore
    let features: ReaderMarkStore
    let account: String
    /// The Kavita username, to tell own collections from promoted ones.
    let username: String?

    public init(client: KavitaClient, store: CollectionStore, features: ReaderMarkStore, account: String, username: String?) {
        self.client = client
        self.store = store
        self.features = features
        self.account = account
        self.username = username
    }

    /// The collection list (one request). False when the server has no collections API.
    @discardableResult
    public func refresh() async throws -> Bool {
        let listedAt = Date()
        let all: [KavitaCollection]
        do {
            all = try await client.collections(ownedOnly: false).map(\.0)
        } catch ConnectionError.server(status: 404) {
            try features.setAvailable(false, .collections, account: account)
            return false
        }
        try features.setAvailable(true, .collections, account: account)
        var listed = all.map { $0.listed(username: username) }
        if username == nil {
            let own = Set(try await client.collections(ownedOnly: true).map(\.0.id))
            for index in listed.indices { listed[index].isOwn = own.contains(listed[index].serverId) }
        }
        try store.merge(listed, account: account, listedAt: listedAt)
        return true
    }

    /// One collection's series (when it's opened). Returns them, to cache for the grid.
    @discardableResult
    public func series(of collection: CollectionRow) async throws -> [(KavitaSeries, raw: Data)] {
        guard let id = collection.id, let serverId = collection.serverId else { return [] }
        let listedAt = Date()
        let series = try await client.series(inCollection: serverId)
        try store.mergeSeries(series.map(\.0.id), collectionId: id, listedAt: listedAt)
        return series
    }

    /// The own collections a series is in (the series sheet, when it opens).
    public func membership(of seriesId: Int) async throws {
        let askedAt = Date()
        let ids = Set(try await client.collections(ofSeries: seriesId).map(\.id))
        try store.mergeMembership(ids, seriesId: seriesId, account: account, listedAt: askedAt)
    }
}
