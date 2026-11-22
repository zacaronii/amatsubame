import Core
import Foundation

/// Brings a bookmark or highlight on Kavita up to date with its row (`ReaderMark`): makes,
/// changes or removes it. The job carries only the row's id, so edits made while it waited go
/// with it, and a mark made and removed before it was sent never reaches the server.
public struct KavitaReaderMarkHandler: OutboxHandler {
    public let kind = OutboxJobKind.kavitaReaderMark
    let makeClient: @Sendable () throws -> KavitaClient?
    let store: ReaderMarkStore

    public init(store: ReaderMarkStore, makeClient: @escaping @Sendable () throws -> KavitaClient?) {
        self.store = store
        self.makeClient = makeClient
    }

    public func send(_ job: OutboxJob, media: [(field: String, url: URL)]) async throws {
        let payload: ReaderMarkJob
        do {
            payload = try job.decodePayload(ReaderMarkJob.self)
        } catch {
            throw OutboxPermanentFailure("Unreadable bookmark job: \(error.localizedDescription)")
        }
        // Gone already (removed before it was ever sent, or by a refresh).
        guard let mark = try store.mark(payload.markId), let id = mark.id else { return }
        guard let client = try makeClient() else {
            throw ConnectionError.message("Kavita isn't set up.")
        }
        do {
            switch mark.state {
            case .synced:
                return
            case .pendingCreate:
                try store.didSend(mark, serverId: try await create(mark, client))
            case .pendingUpdate:
                try store.didSend(mark, serverId: try await update(mark, client))
            case .pendingDelete:
                try await delete(mark, client)
                try store.didRemove(id)
            }
        } catch let error {
            try await settle(error, mark: mark, client: client)
        }
    }

    // MARK: Each kind

    /// Kavita's id for the new mark (annotations only; the others are found by page).
    private func create(_ mark: ReaderMark, _ client: KavitaClient) async throws(ConnectionError) -> Int? {
        switch mark.kind {
        case .highlight:
            return try await client.createAnnotation(KavitaAnnotation(mark)).id
        case .bookBookmark:
            try await client.createPersonalToC(KavitaCreatePersonalToC(mark))
            return nil
        case .pageBookmark:
            try await client.bookmarkPage(KavitaPageBookmark(mark))
            return nil
        }
    }

    /// Only a highlight's note and colour change. One removed meanwhile on another device is
    /// made again (once): Kavita answers 400 for it, and the annotation's own address is a 404.
    private func update(_ mark: ReaderMark, _ client: KavitaClient) async throws(ConnectionError) -> Int? {
        guard mark.kind == .highlight else { return mark.serverId }
        guard let serverId = mark.serverId else { return try await create(mark, client) }
        do {
            return try await client.updateAnnotation(KavitaAnnotation(mark)).id
        } catch .server(status: 400) {
            guard try await client.annotation(id: serverId) == nil else { throw .server(status: 400) }
            var again = mark
            again.serverId = nil
            return try await create(again, client)
        }
    }

    /// Already gone counts as done.
    private func delete(_ mark: ReaderMark, _ client: KavitaClient) async throws(ConnectionError) {
        switch mark.kind {
        case .highlight:
            // Never made on the server (or the make is still to come, which then finds no row).
            guard let serverId = mark.serverId else { return }
            do {
                try await client.deleteAnnotation(id: serverId)
            } catch .server(status: 400) {
                guard try await client.annotation(id: serverId) == nil else { throw .server(status: 400) }
            }
        case .bookBookmark:
            try await client.deletePersonalToC(chapterId: mark.chapterId, page: mark.page, title: mark.title ?? "Page \(mark.page + 1)")
        case .pageBookmark:
            try await client.unbookmarkPage(KavitaPageBookmark(mark))
        }
    }

    // MARK: When the server says no

    /// A server that can't keep this kind of mark stops being offered it, and the unsent marks
    /// of that kind go, so nothing waits to sync for ever. Other refusals need the user;
    /// everything else is tried again later.
    private func settle(_ error: any Error, mark: ReaderMark, client: KavitaClient) async throws {
        guard let error = error as? ConnectionError else { throw error }
        switch (mark.kind, error) {
        case (.highlight, .server(status: 404)):
            // Kavita before 0.8.8: no annotations.
            try store.setAvailable(false, .annotations, account: mark.account)
            return
        case (.pageBookmark, .unauthorized):
            // Without the Bookmark role Kavita refuses (403). A key that stopped working is a 401
            // too, so ask who this is before deciding.
            if let user = try? await client.currentUser(), !KavitaReaderMarkSync.canBookmarkPages(user) {
                try store.setAvailable(false, .pageBookmarks, account: mark.account)
                return
            }
            throw OutboxPermanentFailure("Kavita didn't accept the key. Sign in again in Settings.")
        case (_, .server(let status)) where (400..<500).contains(status) && status != 408 && status != 429:
            throw OutboxPermanentFailure("Kavita refused the \(mark.kind == .highlight ? "highlight" : "bookmark") (HTTP \(status)).")
        default:
            throw error
        }
    }
}

/// Fetches a series' marks from Kavita and brings the device's copy up to date.
public struct KavitaReaderMarkSync: Sendable {
    let client: KavitaClient
    let store: ReaderMarkStore
    let outbox: OutboxStore
    let account: String

    public init(client: KavitaClient, store: ReaderMarkStore, outbox: OutboxStore, account: String) {
        self.client = client
        self.store = store
        self.outbox = outbox
        self.account = account
    }

    /// Admins can always bookmark; others need the Bookmark role.
    static func canBookmarkPages(_ user: KavitaUser) -> Bool {
        user.roles.contains("Admin") || user.roles.contains("Bookmark")
    }

    /// A manga series: its page bookmarks. A book: its highlights, and the bookmarks of the
    /// volumes in `chapters` (Kavita lists those per volume). Throws when Kavita can't be
    /// reached, after keeping whatever came back.
    public func refresh(seriesId: Int, libraryId: Int, isBook: Bool, chapters: [(chapterId: Int, volumeId: Int)] = []) async throws {
        let user = try await client.currentUser()
        if isBook {
            do {
                let mine = try await client.annotations(seriesId: seriesId).filter { $0.ownerUserId == user.id }
                try store.setAvailable(true, .annotations, account: account)
                try store.merge(mine.map { $0.mark(account: account) }, account: account, kinds: [.highlight],
                                scope: { $0.seriesId == seriesId }, outbox: outbox)
            } catch ConnectionError.server(status: 404) {
                try store.setAvailable(false, .annotations, account: account)
            }
            var listed: [ReaderMark] = [], covered = Set<Int>()
            for chapter in chapters {
                let entries = try await client.personalToC(chapterId: chapter.chapterId)
                listed += entries.map { $0.mark(account: account, libraryId: libraryId, seriesId: seriesId, volumeId: chapter.volumeId) }
                covered.insert(chapter.chapterId)
            }
            try store.merge(listed, account: account, kinds: [.bookBookmark], scope: { covered.contains($0.chapterId) }, outbox: outbox)
        } else {
            try store.setAvailable(Self.canBookmarkPages(user), .pageBookmarks, account: account)
            let bookmarks = try await client.pageBookmarks(seriesId: seriesId)
            try store.merge(bookmarks.map { $0.mark(account: account, libraryId: libraryId) }, account: account, kinds: [.pageBookmark],
                            scope: { $0.seriesId == seriesId }, outbox: outbox)
        }
    }
}
