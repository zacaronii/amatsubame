import Core
import Foundation
import KavitaKit

/// Saves the current page locally on every change and, after a pause in page
/// turning (or on `flush`), queues it for Kavita through the outbox.
@MainActor
public final class ReadingProgressRecorder {
    public let chapter: ReaderChapter
    private let progressStore: ReadingProgressStore
    private let outbox: OutboxStore
    private let syncNow: @MainActor () -> Void
    private let debounce: Duration
    private let now: () -> Date
    private var pending: (page: Int, scrollId: String?)?
    private var lastRecorded: (page: Int, scrollId: String?, characters: Int?)?
    private var debounceTask: Task<Void, Never>?

    public init(
        chapter: ReaderChapter,
        progressStore: ReadingProgressStore,
        outbox: OutboxStore,
        syncNow: @escaping @MainActor () -> Void,
        debounce: Duration = .seconds(2),
        now: @escaping () -> Date = Date.init
    ) {
        self.chapter = chapter
        self.progressStore = progressStore
        self.outbox = outbox
        self.syncNow = syncNow
        self.debounce = debounce
        self.now = now
    }

    /// Call when the reader opens at `page` so that simply opening a chapter isn't recorded.
    public func start(at page: Int, scrollId: String? = nil) {
        lastRecorded = (page, scrollId, nil)
    }

    /// `scrollId` is the position within the page for books (Kavita's `bookScrollId`), and
    /// `characters` the characters read in the volume (kept on the device only).
    public func record(page: Int, scrollId: String? = nil, characters: Int? = nil) {
        // A book page inside one long paragraph has the same xpath as the one before: its
        // characters still move on.
        guard lastRecorded?.page != page || lastRecorded?.scrollId != scrollId || lastRecorded?.characters != characters else { return }
        lastRecorded = (page, scrollId, characters)
        try? progressStore.save(LocalReadingProgress(
            chapterId: chapter.chapterId, seriesId: chapter.seriesId, volumeId: chapter.volumeId,
            libraryId: chapter.libraryId, page: page, pages: chapter.pages, updatedAt: now(), scrollId: scrollId,
            characters: characters
        ))
        pending = (page, scrollId)
        debounceTask?.cancel()
        debounceTask = Task { [weak self, debounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    /// Queues any unsent page now (reader closing, app backgrounding).
    public func flush() {
        debounceTask?.cancel()
        debounceTask = nil
        guard let position = pending else { return }
        pending = nil
        let payload = KavitaProgressPayload(
            volumeId: chapter.volumeId, chapterId: chapter.chapterId,
            pageNum: ProgressSyncPolicy.pageNum(forPage: position.page, pages: chapter.pages),
            seriesId: chapter.seriesId, libraryId: chapter.libraryId, bookScrollId: position.scrollId
        )
        do {
            try outbox.enqueue(payload, kind: .kavitaProgress, coalesceKey: "kavita.chapter.\(chapter.chapterId)")
            syncNow()
        } catch {
            pending = position
        }
    }
}
