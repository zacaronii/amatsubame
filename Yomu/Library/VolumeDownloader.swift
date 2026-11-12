import AppCommon
import Core
import Foundation
import KavitaKit
import Observation
import OCR
import Readers

/// Keeps Kavita volumes on the device: every manga page (pinned in the page cache) or the
/// unpacked EPUB (pinned in the book store). Runs while the app is open, one volume at a
/// time, oldest first. A manga volume counts as downloaded once its pages are in; reading
/// its text by OCR (so lookups are instant offline) follows as a separate step.
@MainActor @Observable
final class VolumeDownloader {
    /// What's needed to show and remove a download.
    nonisolated struct Extra: Codable, Equatable, Sendable {
        var isEpub: Bool
        var pages: Int
        var seriesId: Int
        /// Pages are in, text not yet read by OCR.
        var textPending: Bool?
        /// Queued by automatic downloads rather than by the user.
        var isAutomatic: Bool?
    }

    /// What a download is doing right now, for its row.
    struct Activity: Equatable {
        var text: String
        var fraction: Double
    }

    /// Every volume download, by chapter id (kept current from the store).
    private(set) var records: [Int: DownloadRecord] = [:]
    /// What a download is doing: "Pages 12 of 180", then "Reading text 12 of 180".
    private(set) var activity: [Int64: Activity] = [:]
    private(set) var lastError: String?

    @ObservationIgnored private let store: DownloadStore
    @ObservationIgnored private let database: AppDatabase
    @ObservationIgnored private let pages: MangaPageRepository
    @ObservationIgnored private let pageCache: PageCacheStore
    @ObservationIgnored private let books: BookRepository
    @ObservationIgnored private let ocr: OCRService
    @ObservationIgnored private let reachability: Reachability
    /// Downloads paused or deleted while running: the loop stops at the next page.
    @ObservationIgnored private var stopped: Set<Int64> = []
    @ObservationIgnored private var wake: AsyncStream<Void>.Continuation?
    /// The last download stopped on a connection problem (offline, or Kavita out of reach):
    /// the queue waits and retries instead of failing what's left.
    private(set) var connectionTrouble = false
    /// How long the queue waits after a connection problem before trying again.
    static let retryDelay: Duration = .seconds(30)
    @ObservationIgnored private var wakeText: AsyncStream<Void>.Continuation?
    @ObservationIgnored private var started = false

    init(store: DownloadStore, database: AppDatabase, pages: MangaPageRepository, pageCache: PageCacheStore,
         books: BookRepository, ocr: OCRService, reachability: Reachability) {
        self.store = store
        self.database = database
        self.pages = pages
        self.pageCache = pageCache
        self.books = books
        self.ocr = ocr
        self.reachability = reachability
    }

    // MARK: Lifecycle

    /// Keeps `records` current and works through the queue until cancelled.
    func start() async {
        guard !started else { return }
        started = true
        try? store.requeueInterrupted()
        // Failures are retried once per launch (most were connection problems).
        try? store.requeueFailed(kind: .kavitaChapter)
        async let observing: Void = observe()
        async let working: Void = work()
        async let reading: Void = readTextOfDownloads()
        _ = await (observing, working, reading)
    }

    private func observe() async {
        do {
            for try await all in store.observe(kind: .kavitaChapter) {
                records = Dictionary(all.compactMap { record in Int(record.itemKey).map { ($0, record) } }, uniquingKeysWith: { $1 })
            }
        } catch {}
    }

    private func work() async {
        let (signals, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        wake = continuation
        continuation.yield()
        for await _ in signals {
            while let next = try? store.nextQueued(kind: .kavitaChapter) {
                await process(next)
                if connectionTrouble { await waitToRetry() }
            }
        }
    }

    /// After a connection problem: try again when the device comes back online, when the
    /// user resumes a download, or after `retryDelay`.
    private func waitToRetry() async {
        let wasOnline = reachability.isOnline
        let deadline = ContinuousClock.now + Self.retryDelay
        retryRequested = false
        while ContinuousClock.now < deadline, !retryRequested {
            try? await Task.sleep(for: .seconds(1))
            if !wasOnline && reachability.isOnline { break }
        }
    }
    @ObservationIgnored private var retryRequested = false

    // MARK: Actions

    func download(_ chapter: KavitaChapter, series: KavitaSeries, title: String, automatic: Bool = false) {
        if let existing = records[chapter.id], existing.state == .done || existing.isActive { return }
        let extra = Extra(isEpub: series.isEpub, pages: chapter.pages, seriesId: series.id, isAutomatic: automatic ? true : nil)
        do {
            try store.enqueue(DownloadRecord(
                kind: .kavitaChapter, itemKey: String(chapter.id), seriesKey: String(series.id), seriesTitle: series.displayName,
                title: title, detail: series.isEpub ? "Book" : "\(chapter.pages) pages",
                extra: try JSONEncoder().encode(extra), createdAt: Date()))
            wake?.yield()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func pause(_ record: DownloadRecord) {
        guard let id = record.id else { return }
        stopped.insert(id)
        try? store.setState(id, .paused)
    }

    func resume(_ record: DownloadRecord) {
        guard let id = record.id else { return }
        stopped.remove(id)
        try? store.setState(id, .queued)
        retryRequested = true
        wake?.yield()
    }

    /// Removes the volume from the device (pages or book) and forgets the download.
    func delete(_ record: DownloadRecord) async {
        guard let id = record.id, let chapterId = Int(record.itemKey) else { return }
        stopped.insert(id)
        if Self.extra(record)?.isEpub == true {
            await books.remove(chapterId: chapterId)
        } else {
            try? pageCache.remove(chapterId: chapterId)
        }
        try? store.remove(id)
    }

    nonisolated static func extra(_ record: DownloadRecord) -> Extra? {
        record.extra.flatMap { try? JSONDecoder().decode(Extra.self, from: $0) }
    }

    // MARK: Work

    /// Why queued downloads aren't moving, if the network rule is holding them.
    var waitingReason: String? {
        if !reachability.isOnline { return "Waiting for a connection" }
        if reachability.isExpensive && !DownloadSettings.load(database).allowsCellular { return "Waiting for Wi-Fi" }
        if connectionTrouble { return "Can\u{2019}t reach Kavita; trying again shortly" }
        return nil
    }

    /// Errors that mean "try again later" rather than "this can't be downloaded".
    nonisolated static func isConnectionProblem(_ error: any Error) -> Bool {
        // TLS failures here are usually a captive or half-up network, not a bad certificate.
        if let error = error as? ConnectionError {
            if case .tls = error { return true }
            return error.isTransient
        }
        if let error = error as? URLError { return ConnectionError(error).isTransient }
        if case BookRepository.BookError.unavailable = error { return true }
        return false
    }

    private func process(_ record: DownloadRecord) async {
        guard let id = record.id, let chapterId = Int(record.itemKey), let extra = Self.extra(record) else { return }
        stopped.remove(id)
        // Wait for a network the user allows (Wi-Fi unless cellular is on).
        while !reachability.isOnline || (reachability.isExpensive && !DownloadSettings.load(database).allowsCellular) {
            try? await Task.sleep(for: .seconds(5))
            if stopped.contains(id) || (try? store.download(id: id))??.state != .queued { return }
        }
        try? store.setState(id, .downloading)
        do {
            if extra.isEpub {
                _ = try await books.book(chapterId: chapterId)
                await books.pin(chapterId: chapterId)
                guard !stopped.contains(id) else { return }
                try store.finish(id, file: nil, bytes: Int64(await books.bytes(chapterId: chapterId)))
            } else {
                try await downloadPages(id: id, chapterId: chapterId, count: extra.pages)
                guard !stopped.contains(id) else { return }
                var finished = extra
                finished.textPending = DownloadSettings.load(database).readsDownloadedPages ? true : nil
                try store.finish(id, file: nil, bytes: Int64(try pageCache.bytes(chapterId: chapterId)),
                                 extra: try JSONEncoder().encode(finished))
                wakeText?.yield()
            }
            activity[id] = nil
            connectionTrouble = false
        } catch {
            activity[id] = nil
            guard !stopped.contains(id) else { return }
            if Self.isConnectionProblem(error) {
                // Back in line (pages already fetched stay); the queue waits, then retries.
                connectionTrouble = true
                try? store.setState(id, .queued)
            } else {
                try? store.setState(id, .failed, error: error.localizedDescription)
            }
        }
    }

    /// Every page and the page sizes, pinned so the cache never evicts them.
    private func downloadPages(id: Int64, chapterId: Int, count: Int) async throws {
        _ = try await pages.dimensions(chapterId: chapterId)
        try pageCache.setPinned(chapterId: chapterId, true)
        for page in 0..<count {
            if stopped.contains(id) { return }
            _ = try await pages.pageData(chapterId: chapterId, page: page)
            // Pin as we go, so a long volume can't push its own first pages out.
            try pageCache.setPinned(chapterId: chapterId, true)
            let bytes = Int64(try pageCache.bytes(chapterId: chapterId))
            try store.setProgress(id, done: bytes, total: bytes * Int64(count) / Int64(page + 1))
            activity[id] = Activity(text: "Pages \(page + 1) of \(count)", fraction: Double(page + 1) / Double(max(count, 1)))
        }
    }

    /// Reads the text of downloaded volumes still waiting for it, oldest first, alongside
    /// new downloads. Woken when a volume's pages are in.
    private func readTextOfDownloads() async {
        let (signals, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        wakeText = continuation
        continuation.yield()
        for await _ in signals {
            guard DownloadSettings.load(database).readsDownloadedPages, await ocr.modelsInstalled else { continue }
            while let next = nextTextPending() {
                guard let id = next.id, let chapterId = Int(next.itemKey), var extra = Self.extra(next) else { break }
                stopped.remove(id)
                await readText(id: id, chapterId: chapterId, count: extra.pages)
                activity[id] = nil
                // Turned off meanwhile: leave the rest for later. Deleted: on to the next.
                guard DownloadSettings.load(database).readsDownloadedPages else { break }
                if stopped.contains(id) { continue }
                extra.textPending = nil
                try? store.setExtra(id, try JSONEncoder().encode(extra))
            }
        }
    }

    private func nextTextPending() -> DownloadRecord? {
        (try? store.all(kind: .kavitaChapter))?.first { $0.state == .done && Self.extra($0)?.textPending == true }
    }

    /// Wakes text reading, e.g. after the OCR models are installed or the setting turned on.
    func resumeTextReading() {
        wakeText?.yield()
    }

    /// OCR for every downloaded page (results are saved). Pages already read are skipped.
    private func readText(id: Int64, chapterId: Int, count: Int) async {
        for page in 0..<count {
            if stopped.contains(id) { return }
            activity[id] = Activity(text: "Reading text \(page + 1) of \(count)", fraction: Double(page + 1) / Double(max(count, 1)))
            if await ocr.cachedPage(chapterId: chapterId, page: page) != nil { continue }
            guard let data = pageCache.data(for: PageCacheKey(chapterId: chapterId, page: page)) else { continue }
            _ = try? await ocr.page(chapterId: chapterId, page: page, imageData: data)
        }
    }
}
