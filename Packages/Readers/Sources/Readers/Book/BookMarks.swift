import Core
import Foundation
import Observation

/// A book's highlights, notes and bookmarks, kept on Kavita (its annotations and personal table
/// of contents): the ones in this volume, and the changes made here. Changes go through the
/// outbox, so they work offline and reach Kavita later.
@MainActor @Observable
public final class BookMarks {
    public private(set) var highlights: [ReaderMark] = []
    public private(set) var bookmarks: [ReaderMark] = []
    /// False when this Kavita server has no annotations (before 0.8.8): no highlights or notes.
    public private(set) var canHighlight = true

    let chapter: ReaderChapter
    let account: String
    let store: ReaderMarkStore
    let outbox: OutboxStore
    let syncNow: @MainActor () -> Void
    /// Fetches the book's marks from Kavita (which also finds out whether it has annotations).
    let refresh: @MainActor () async -> Void
    /// Called when the volume's marks change, to draw them on the page.
    @ObservationIgnored var onChange: (() -> Void)?

    public init(chapter: ReaderChapter, account: String, store: ReaderMarkStore, outbox: OutboxStore,
                syncNow: @escaping @MainActor () -> Void, refresh: @escaping @MainActor () async -> Void) {
        self.chapter = chapter
        self.account = account
        self.store = store
        self.outbox = outbox
        self.syncNow = syncNow
        self.refresh = refresh
    }

    /// Kavita's default colour for each highlight slot (its web reader's, at 40 %).
    public static let slotColors = ["rgba(0, 255, 255, 0.4)", "rgba(0, 255, 0, 0.4)", "rgba(255, 255, 0, 0.4)",
                                    "rgba(255, 165, 0, 0.4)", "rgba(255, 0, 255, 0.4)"]

    public static func color(_ slot: Int) -> String { slotColors[min(max(slot, 0), slotColors.count - 1)] }

    /// Follows the volume's marks until cancelled.
    public func follow() async {
        canHighlight = available
        Task { [weak self] in
            await self?.refresh()
            guard let self else { return }
            canHighlight = available
        }
        do {
            for try await marks in store.observe(account: account, seriesId: chapter.seriesId) {
                let here = marks.filter { $0.chapterId == chapter.chapterId }
                highlights = here.filter { $0.kind == .highlight }
                bookmarks = here.filter { $0.kind == .bookBookmark }
                canHighlight = available
                onChange?()
            }
        } catch {}
    }

    private var available: Bool { (try? store.isAvailable(.annotations, account: account)) ?? true }

    // MARK: Highlights

    @discardableResult
    func addHighlight(page: Int, xpath: String, endXPath: String, text: String, slot: Int) -> ReaderMark? {
        guard canHighlight else { return nil }
        let now = Date()
        let mark = try? store.add(ReaderMark(account: account, kind: .highlight, libraryId: chapter.libraryId, seriesId: chapter.seriesId,
                                             volumeId: chapter.volumeId, chapterId: chapter.chapterId, page: page, xpath: xpath,
                                             endXPath: endXPath, text: text, slot: slot, state: .pendingCreate, createdAt: now, updatedAt: now),
                                  outbox: outbox)
        syncNow()
        return mark
    }

    public func edit(_ mark: ReaderMark, note: String?, slot: Int) {
        guard let id = mark.id else { return }
        try? store.edit(id, note: note, slot: slot, outbox: outbox)
        syncNow()
    }

    public func remove(_ mark: ReaderMark) {
        guard let id = mark.id else { return }
        try? store.remove(id, outbox: outbox)
        syncNow()
    }

    // MARK: Bookmarks

    /// The bookmark at this place on the page, if there is one.
    public func bookmark(page: Int, xpath: String?) -> ReaderMark? {
        bookmarks.first { $0.page == page && $0.xpath == xpath }
    }

    /// Bookmarks the place (titled by the words it starts with), or removes its bookmark.
    func toggleBookmark(page: Int, xpath: String?, text: String) {
        if let existing = bookmark(page: page, xpath: xpath) {
            remove(existing)
            return
        }
        let now = Date()
        let title = Self.uniqueTitle(text.isEmpty ? "Page \(page + 1)" : text, among: bookmarks.filter { $0.page == page }.compactMap(\.title))
        try? store.add(ReaderMark(account: account, kind: .bookBookmark, libraryId: chapter.libraryId, seriesId: chapter.seriesId,
                                  volumeId: chapter.volumeId, chapterId: chapter.chapterId, page: page, xpath: xpath, text: text,
                                  title: title, state: .pendingCreate, createdAt: now, updatedAt: now), outbox: outbox)
        syncNow()
    }

    /// Kavita removes a book bookmark by its page and title, so titles on one page differ.
    static func uniqueTitle(_ title: String, among taken: [String]) -> String {
        guard taken.contains(title) else { return title }
        var number = 2
        while taken.contains("\(title) (\(number))") { number += 1 }
        return "\(title) (\(number))"
    }
}
