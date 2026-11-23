import Core
import Foundation

// Verified against Kavita 0.9.1.23 (2026-11-22) with a test account (source: develop and the
// release tags):
// - `POST /api/ReadingList/lists?includePromoted=` (paged; without a page size, every list):
//   id, title, promoted, ownerUserName (0.8.8+), itemCount (0.8.4+), provider and canSync (0.9.0+;
//   a list that syncs from outside is read-only here). Routes are in 0.7.8 already.
// - `POST create {title}` answers the list (with its id); a title the user already has (Kavita's
//   ToNormalized) is a 400 with a translated message.
// - `GET items?readingListId=` in Kavita's order (404 once the list is gone). A chapter is in a list
//   at most once: `update-by-chapter` with one already there is a 200 and adds nothing.
// - `POST update-position {readingListItemId, toPosition}`: Kavita takes the item out and inserts it
//   at `toPosition` (a position past the end puts it last). `POST delete-item` renumbers the rest;
//   both are a 200 for an item that's gone, and a 400 ("permission") for a list that's gone.
//   Taking out the last item keeps the list. `DELETE ?readingListId` (404 once gone).
// - Kavita's cleanup task (daily unless the admin changes it) removes lists with no items.

public struct KavitaReadingList: Decodable, Equatable, Sendable {
    public var id: Int
    public var title: String
    public var promoted: Bool?
    public var ownerUserName: String?
    public var itemCount: Int?
    public var provider: Int?
    public var canSync: Bool?
}

public struct KavitaReadingListItem: Decodable, Equatable, Sendable {
    public var id: Int
    public var order: Int?
    public var chapterId: Int
    public var seriesId: Int
    public var volumeId: Int
    public var libraryId: Int
    public var seriesFormat: Int?
    public var seriesName: String?
    public var title: String?

    func listed() -> ReadingListStore.ListedItem {
        ReadingListStore.ListedItem(serverItemId: id, chapter: ReadingListChapter(
            chapterId: chapterId, seriesId: seriesId, volumeId: volumeId, libraryId: libraryId, format: seriesFormat ?? 2,
            seriesName: seriesName ?? "", title: title ?? ""))
    }
}

extension KavitaClient {
    /// Every reading list the user sees (own, and promoted ones of others when asked), all pages.
    public func readingLists(includePromoted: Bool, pageSize: Int = 100) async throws(ConnectionError) -> [KavitaReadingList] {
        var all: [KavitaReadingList] = []
        var page = 1
        while true {
            let request = try jsonRequest("POST", "api/ReadingList/lists", query: [
                URLQueryItem(name: "includePromoted", value: String(includePromoted)),
                URLQueryItem(name: "pageNumber", value: String(page)), URLQueryItem(name: "pageSize", value: String(pageSize)),
            ], body: [String: String]())
            let result: KavitaPage<(KavitaReadingList, raw: Data)> = try await paged(request)
            all += result.items.map(\.0)
            guard result.pagination.map({ $0.currentPage < $0.totalPages }) ?? (result.items.count == pageSize), page < 200 else { return all }
            page += 1
        }
    }

    /// A list's items in Kavita's order; nil when the list is gone.
    public func readingListItems(_ listId: Int) async throws(ConnectionError) -> [KavitaReadingListItem]? {
        do {
            return try await http.decode([KavitaReadingListItem].self, from: request("api/ReadingList/items", query: [
                URLQueryItem(name: "readingListId", value: String(listId)),
            ]), decoder: KavitaJSON.decoder)
        } catch .server(status: 404) {
            return nil
        }
    }

    // MARK: Writes (call only from the outbox handler)

    public func createReadingList(title: String) async throws(ConnectionError) -> KavitaReadingList {
        try await http.decode(KavitaReadingList.self, from: jsonRequest("POST", "api/ReadingList/create", body: ["title": title]), decoder: KavitaJSON.decoder)
    }

    public func addToReadingList(_ listId: Int, chapterId: Int, seriesId: Int) async throws(ConnectionError) {
        _ = try await http.send(jsonRequest("POST", "api/ReadingList/update-by-chapter",
                                            body: ["readingListId": listId, "chapterId": chapterId, "seriesId": seriesId]))
    }

    public func removeFromReadingList(_ listId: Int, itemId: Int) async throws(ConnectionError) {
        _ = try await http.send(jsonRequest("POST", "api/ReadingList/delete-item", body: ["readingListId": listId, "readingListItemId": itemId]))
    }

    public func moveInReadingList(_ listId: Int, itemId: Int, to position: Int) async throws(ConnectionError) {
        _ = try await http.send(jsonRequest("POST", "api/ReadingList/update-position",
                                            body: ["readingListId": listId, "readingListItemId": itemId, "fromPosition": 0, "toPosition": position]))
    }

    public func deleteReadingList(_ listId: Int) async throws(ConnectionError) {
        var request = request("api/ReadingList", query: [URLQueryItem(name: "readingListId", value: String(listId))])
        request.httpMethod = "DELETE"
        _ = try await http.send(request)
    }
}

/// Sends a reading list's create or delete, one item's add or remove, or one move, as the rows are
/// when the job runs.
public struct KavitaReadingListHandler: OutboxHandler {
    public let kind = OutboxJobKind.kavitaReadingList
    let store: ReadingListStore
    let features: ReaderMarkStore
    let outbox: OutboxStore
    let account: @Sendable () -> String?
    let makeClient: @Sendable () throws -> KavitaClient?

    public init(store: ReadingListStore, features: ReaderMarkStore, outbox: OutboxStore, account: @escaping @Sendable () -> String? = { nil },
                makeClient: @escaping @Sendable () throws -> KavitaClient?) {
        self.store = store
        self.features = features
        self.outbox = outbox
        self.account = account
        self.makeClient = makeClient
    }

    public func send(_ job: OutboxJob, media: [(field: String, url: URL)]) async throws {
        let payload: ReadingListJob
        do {
            payload = try job.decodePayload(ReadingListJob.self)
        } catch {
            throw OutboxPermanentFailure("Unreadable reading list job: \(error.localizedDescription)")
        }
        guard let list = try store.list(payload.listId), let id = list.id else { return }
        // Waits are decided from the device's rows only, before the client is made, so a job
        // looked at again every 30 s while another backs off costs a couple of local reads.
        if payload.moveId != nil, try store.hasEarlierChange(account: list.account, listId: id, before: job.id) {
            throw OutboxWait("Waiting for an earlier change to \u{201C}\(list.title)\u{201D}.")
        }
        if payload.moveId != nil || payload.chapterId != nil, list.serverId == nil, list.state == .pendingCreate,
           try store.isQueued(ReadingListJob(account: list.account, listId: id)) {
            throw OutboxWait("Waiting for the reading list \u{201C}\(list.title)\u{201D} to be made.")
        }
        guard let client = try makeClient() else { throw ConnectionError.message("Kavita isn't set up.") }
        if let current = account(), current != list.account {
            throw ConnectionError.message("This belongs to another Kavita account.")
        }
        do {
            if let moveId = payload.moveId {
                // In order (checked above): an earlier add or move of the list backing off would
                // otherwise be overtaken, and Kavita would end in another order than the device shows.
                try await move(moveId, in: list, client)
            } else if let chapterId = payload.chapterId {
                try await sendItem(chapterId, of: list, client)
            } else {
                switch list.state {
                case .pendingCreate: try await create(list, client)
                case .pendingDelete:
                    if let serverId = list.serverId {
                        do { try await client.deleteReadingList(serverId) } catch .server(status: 404) {}
                    }
                    try store.didDelete(id)
                case .synced: return
                }
            }
        } catch let error as ConnectionError {
            switch error {
            case .server(let status) where (400..<500).contains(status) && status != 408 && status != 429:
                if status == 404 {
                    // Before Kavita 0.7.8 there are no reading lists; only the list route decides it.
                    do {
                        _ = try await client.readingLists(includePromoted: false, pageSize: 1)
                    } catch .server(status: 404) {
                        try features.setAvailable(false, .readingLists, account: list.account)
                        if list.state == .pendingCreate { try store.dropList(id) }
                        return
                    }
                }
                throw OutboxPermanentFailure("Kavita refused the change to \u{201C}\(list.title)\u{201D} (HTTP \(status)).")
            default:
                throw error
            }
        }
    }

    // MARK: The list

    /// Safe to run twice: an own list with the title this device doesn't know is taken as the one
    /// it made. A 400 for the title also means it's there (a lost answer): it's looked for again.
    private func create(_ list: ReadingListRow, _ client: KavitaClient) async throws {
        guard let id = list.id else { return }
        if let found = try await made(list, client) {
            try store.didCreate(id, serverId: found)
            return
        }
        let created: Int
        do {
            created = try await client.createReadingList(title: list.title).id
        } catch .server(status: 400) {
            guard let found = try await made(list, client) else {
                try store.dropList(id)
                throw OutboxPermanentFailure("Kavita couldn't make the reading list \u{201C}\(list.title)\u{201D}.")
            }
            try store.didCreate(id, serverId: found)
            return
        }
        if try !store.didCreate(id, serverId: created) {
            // Deleted here while the create was on its way: what it just made goes too.
            try await client.deleteReadingList(created)
        }
    }

    private func made(_ list: ReadingListRow, _ client: KavitaClient) async throws -> Int? {
        let known = try store.knownServerIds(account: list.account)
        let title = CollectionRow.normalized(list.title)
        return try await client.readingLists(includePromoted: false)
            .filter { CollectionRow.normalized($0.title) == title && !known.contains($0.id) }.map(\.id).max()
    }

    /// The list on Kavita is gone. Empty as last known (new, or emptied from here): Kavita's cleanup
    /// took it, so it's made again with its waiting adds (at most twice). With items: deleted
    /// elsewhere, and it goes here too.
    private func gone(_ list: ReadingListRow) throws {
        guard let id = list.id else { return }
        if try store.recreate(id, outbox: outbox) {
            throw OutboxWait("Kavita removed the empty reading list \u{201C}\(list.title)\u{201D}; making it again.")
        }
        if list.kavitaItemCount == 0 {
            try store.dropList(id)
            throw OutboxPermanentFailure("Kavita didn't keep the reading list \u{201C}\(list.title)\u{201D}.")
        }
        try store.dropList(id)
    }

    /// The items as Kavita has them (read once, then kept up to date by the moves here); nil when
    /// the list is gone.
    private func kavitaItems(_ list: ReadingListRow, _ serverId: Int, _ client: KavitaClient) async throws -> [(chapterId: Int, serverItemId: Int?)]? {
        guard let id = list.id else { return nil }
        if try store.itemsAreFresh(id) { return try store.kavitaItems(listId: id) }
        let listedAt = Date()
        guard let items = try await client.readingListItems(serverId) else { return nil }
        try store.mergeItems(items.map { $0.listed() }, listId: id, listedAt: listedAt)
        return items.map { ($0.chapterId, $0.id) }
    }

    // MARK: Items

    private func sendItem(_ chapterId: Int, of list: ReadingListRow, _ client: KavitaClient) async throws {
        guard let id = list.id, let row = try store.item(listId: id, chapterId: chapterId),
              row.state == .pendingAdd || row.state == .pendingRemove else { return }
        guard list.state != .pendingDelete else { return }
        guard let serverId = list.serverId else {
            if list.state == .pendingCreate, try store.isQueued(ReadingListJob(account: list.account, listId: id)) {
                throw OutboxWait("Waiting for the reading list \u{201C}\(list.title)\u{201D} to be made.")
            }
            try store.dropItem(row)
            return
        }
        if row.state == .pendingAdd {
            do {
                try await client.addToReadingList(serverId, chapterId: chapterId, seriesId: row.seriesId)
            } catch .server(status: 400) {
                guard try await client.readingListItems(serverId) == nil else {
                    throw OutboxPermanentFailure("Kavita refused to add to \u{201C}\(list.title)\u{201D} (HTTP 400).")
                }
                try gone(list)
                return
            }
            try store.didSend(row)
            return
        }
        // A remove: by the item's id, found by its chapter.
        guard let items = try await kavitaItems(list, serverId, client) else {
            // The list is gone: nothing to take it out of.
            try store.dropList(id)
            return
        }
        guard let itemId = items.first(where: { $0.chapterId == chapterId })?.serverItemId else {
            try store.didSend(row)
            return
        }
        try await client.removeFromReadingList(serverId, itemId: itemId)
        try store.didSend(row)
    }

    // MARK: Moves

    private func move(_ moveId: Int64, in list: ReadingListRow, _ client: KavitaClient) async throws {
        guard let id = list.id, let move = try store.moveRow(moveId) else { return }
        guard let serverId = list.serverId else {
            if list.state == .pendingCreate, try store.isQueued(ReadingListJob(account: list.account, listId: id)) {
                throw OutboxWait("Waiting for the reading list \u{201C}\(list.title)\u{201D} to be made.")
            }
            try store.dropMove(moveId)
            return
        }
        guard let items = try await kavitaItems(list, serverId, client) else {
            try store.dropMove(moveId)
            return
        }
        guard let itemId = items.first(where: { $0.chapterId == move.chapterId })?.serverItemId else {
            // Not on Kavita: its add, if any, was queued earlier and failed for good. Nothing to move.
            try store.dropMove(moveId)
            return
        }
        let order = items.map(\.chapterId)
        let target = ReadingListStore.apply(move.chapterId, after: move.anchorChapters, to: order)
        guard target != order, let position = target.firstIndex(of: move.chapterId) else {
            // Already there (also a job run again after the app died).
            try store.dropMove(moveId)
            return
        }
        // Kavita takes the item out, then inserts it at `position` among the rest.
        try await client.moveInReadingList(serverId, itemId: itemId, to: position)
        try store.didMove(moveId, kavitaOrder: target, listId: id)
    }
}

/// Fetches reading lists from Kavita and brings the device's copy up to date.
public struct KavitaReadingListSync: Sendable {
    let client: KavitaClient
    let store: ReadingListStore
    let features: ReaderMarkStore
    let account: String
    let username: String?

    public init(client: KavitaClient, store: ReadingListStore, features: ReaderMarkStore, account: String, username: String?) {
        self.client = client
        self.store = store
        self.features = features
        self.account = account
        self.username = username
    }

    /// The lists (one request; two before Kavita 0.8.8, which doesn't say whose a list is).
    @discardableResult
    public func refresh() async throws -> Bool {
        let listedAt = Date()
        let all: [KavitaReadingList]
        do {
            all = try await client.readingLists(includePromoted: true)
        } catch ConnectionError.server(status: 404) {
            try features.setAvailable(false, .readingLists, account: account)
            return false
        }
        try features.setAvailable(true, .readingLists, account: account)
        var own: Set<Int>?
        if all.contains(where: { $0.ownerUserName == nil }) || username == nil {
            own = Set(try await client.readingLists(includePromoted: false).map(\.id))
        }
        let listed = all.map { list in
            ReadingListStore.Listed(
                serverId: list.id, title: list.title,
                isOwn: own.map { $0.contains(list.id) } ?? (list.ownerUserName?.caseInsensitiveCompare(username ?? "") == .orderedSame),
                owner: list.ownerUserName, promoted: list.promoted ?? false,
                isSynced: (list.provider ?? 0) != 0 || list.canSync == true, itemCount: list.itemCount)
        }
        try store.merge(listed, account: account, listedAt: listedAt)
        return true
    }

    /// A list's items (when it's opened). False when Kavita no longer has it.
    @discardableResult
    public func items(of list: ReadingListRow) async throws -> Bool {
        guard let id = list.id, let serverId = list.serverId else { return true }
        let listedAt = Date()
        guard let items = try await client.readingListItems(serverId) else { return false }
        try store.mergeItems(items.map { $0.listed() }, listId: id, listedAt: listedAt)
        return true
    }
}
