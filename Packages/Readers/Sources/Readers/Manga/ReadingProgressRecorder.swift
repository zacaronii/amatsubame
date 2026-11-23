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
    /// The page waiting to be queued, and when it was turned (the job's `madeAt`).
    private var pending: (page: Int, scrollId: String?, at: Date)?
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
        let turned = now()
        try? progressStore.save(LocalReadingProgress(
            chapterId: chapter.chapterId, seriesId: chapter.seriesId, volumeId: chapter.volumeId,
            libraryId: chapter.libraryId, page: page, pages: chapter.pages, updatedAt: turned, scrollId: scrollId,
            characters: characters
        ))
        pending = (page, scrollId, turned)
        debounceTask?.cancel()
        debounceTask = Task { [weak self, debounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    /// Whether this chapter has a progress change queued and not sent yet: then this device's
    /// place is where to open (`LocalReadingProgress.devicesPlaceWins`).
    public var hasUnsentChange: Bool {
        (try? outbox.hasUnsentProgress(chapterId: chapter.chapterId, seriesId: chapter.seriesId)) ?? false
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
            seriesId: chapter.seriesId, libraryId: chapter.libraryId, bookScrollId: position.scrollId, madeAt: position.at
        )
        do {
            try outbox.enqueue(payload, kind: .kavitaProgress, coalesceKey: "kavita.chapter.\(chapter.chapterId)")
            syncNow()
        } catch {
            pending = position
        }
    }
}
