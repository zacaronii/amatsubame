import Core
import Foundation
import Observation

/// The manga reader's page bookmarks, kept on Kavita (its page bookmarks): which pages of this
/// chapter are bookmarked, and the button that adds or removes one. Changes go through the
/// outbox, so they work offline and reach Kavita later.
@MainActor @Observable
public final class PageBookmarks {
    /// The chapter's bookmarked pages, with their rows.
    public private(set) var pages: [Int: Int64] = [:]
    /// False when this Kavita account can't keep page bookmarks (no Bookmark role).
    public private(set) var canBookmark = true

    let chapter: ReaderChapter
    let account: String
    let store: ReaderMarkStore
    let outbox: OutboxStore
    let syncNow: @MainActor () -> Void
    /// Fetches the series' bookmarks from Kavita (which also finds out what the account may do).
    let refresh: @MainActor () async -> Void

    public init(chapter: ReaderChapter, account: String, store: ReaderMarkStore, outbox: OutboxStore,
                syncNow: @escaping @MainActor () -> Void, refresh: @escaping @MainActor () async -> Void) {
        self.chapter = chapter
        self.account = account
        self.store = store
        self.outbox = outbox
        self.syncNow = syncNow
        self.refresh = refresh
    }

    /// Follows the chapter's bookmarks until cancelled.
    public func follow() async {
        canBookmark = (try? store.isAvailable(.pageBookmarks, account: account)) ?? true
        Task { [weak self] in
            await self?.refresh()
            guard let self else { return }
            canBookmark = (try? store.isAvailable(.pageBookmarks, account: account)) ?? true
        }
        do {
            for try await marks in store.observe(account: account, seriesId: chapter.seriesId) {
                var pages: [Int: Int64] = [:]
                for mark in marks where mark.kind == .pageBookmark && mark.chapterId == chapter.chapterId {
                    if let id = mark.id { pages[mark.page] = id }
                }
                self.pages = pages
            }
        } catch {}
    }

    public func isBookmarked(_ page: Int) -> Bool { pages[page] != nil }

    /// Adds or removes the page's bookmark.
    public func toggle(_ page: Int) {
        if let id = pages[page] {
            try? store.remove(id, outbox: outbox)
        } else {
            guard canBookmark else { return }
            let now = Date()
            try? store.add(ReaderMark(account: account, kind: .pageBookmark, libraryId: chapter.libraryId, seriesId: chapter.seriesId,
                                      volumeId: chapter.volumeId, chapterId: chapter.chapterId, page: page, state: .pendingCreate,
                                      createdAt: now, updatedAt: now), outbox: outbox)
        }
        syncNow()
    }
}
