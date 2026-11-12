import Core
import CoreGraphics
import Foundation
import KavitaKit
import Lookup
import OCR
import Observation

/// How long the last tap-to-lookup took, for the debug timings overlay.
public struct LookupTimings: Equatable, Sendable {
    /// Nil when the page's text was already known (cached or OCR'd ahead).
    public var ocr: Duration?
    public var lookup: Duration

    public var total: Duration { (ocr ?? .zero) + lookup }
}

@MainActor @Observable
public final class MangaReaderModel {
    public enum LoadState: Equatable {
        case loading
        case ready
        case failed(String)
    }

    public let chapter: ReaderChapter
    public let nextChapter: ReaderChapter?
    public let pages: MangaPageRepository
    public private(set) var state = LoadState.loading
    public private(set) var dimensions: [KavitaPageDimension] = []
    /// Lowest page index on screen.
    public private(set) var currentPage = 0
    public private(set) var startPage = 0
    public var showsChrome = false
    /// Set by the view from the available space when spreads are on `auto`.
    public var spreadsFitScreen = false
    public var settings: MangaReaderSettings {
        didSet {
            guard settings != oldValue else { return }
            try? settingsStore.save(settings, seriesId: chapter.seriesId)
        }
    }

    /// Recognized text per page, filled as pages are OCR'd (or loaded from the cache).
    public private(set) var pageText: [Int: OCRPage] = [:]
    /// A page turn asked for outside the paged view (menu commands); the view owns the position.
    public struct PageRequest: Equatable, Sendable {
        public var delta: Int
        let id = UUID()
    }
    public private(set) var pageRequest: PageRequest?

    /// Turns forward (+1) or back (−1) in reading order.
    public func requestPage(_ delta: Int) {
        pageRequest = PageRequest(delta: delta)
    }

    /// The lookup popup for the last tapped text, and where on screen it was (global coordinates).
    public var popup: LookupPopupModel?
    /// The page of the last lookup, until you page away from it: a spread that splits (folding
    /// the iPhone Duo, which also closes the popup) shows that page rather than the spread's first.
    public private(set) var popupPage: Int?
    public private(set) var popupAnchor: CGRect = .zero
    public private(set) var lastTimings: LookupTimings?
    public private(set) var ocrMessage: String?
    /// The box being drawn for manual OCR, in the page's own coordinates.
    public var selection: (page: Int, rect: CGRect)?
    /// True from a long press until a box is drawn or selection is cancelled.
    public private(set) var isSelecting = false

    public let ocr: OCRService?
    public let lookup: LookupService?
    private let settingsStore: MangaReaderSettingsStore
    private let progressStore: ReadingProgressStore
    private let recorder: ReadingProgressRecorder
    private var ocrTask: Task<Void, Never>?

    public init(
        chapter: ReaderChapter,
        nextChapter: ReaderChapter?,
        pages: MangaPageRepository,
        settingsStore: MangaReaderSettingsStore,
        progressStore: ReadingProgressStore,
        outbox: OutboxStore,
        ocr: OCRService? = nil,
        lookup: LookupService? = nil,
        syncNow: @escaping @MainActor () -> Void
    ) {
        self.ocr = ocr
        self.lookup = lookup
        self.chapter = chapter
        self.nextChapter = nextChapter
        self.pages = pages
        self.settingsStore = settingsStore
        self.progressStore = progressStore
        recorder = ReadingProgressRecorder(chapter: chapter, progressStore: progressStore, outbox: outbox, syncNow: syncNow)
        settings = (try? settingsStore.settings(seriesId: chapter.seriesId)) ?? .default
    }

    public var pageCount: Int { dimensions.isEmpty ? chapter.pages : dimensions.count }

    public var usesSpreads: Bool {
        switch settings.spreads {
        case .on: true
        case .off: false
        case .auto: spreadsFitScreen
        }
    }

    /// What the paged reader shows per swipe.
    public var slots: [[Int]] {
        SpreadLayout.slots(
            pageCount: pageCount,
            widePages: Set(dimensions.filter(\.isWide).map(\.pageNumber)),
            spreads: usesSpreads,
            coverAlone: settings.coverAlone
        )
    }

    public func aspectRatio(of page: Int) -> Double {
        dimensions.indices.contains(page) ? dimensions[page].aspectRatio : 0.7
    }

    public func load() async {
        state = .loading
        do {
            dimensions = try await pages.dimensions(chapterId: chapter.chapterId)
        } catch {
            // Its page sizes are saved when a download starts, so this volume isn't on the device.
            let unreachable = (error as? ConnectionError)?.isTransient == true || error is URLError
            state = .failed(unreachable
                ? "This volume isn\u{2019}t downloaded yet, and Kavita can\u{2019}t be reached. Try again when you\u{2019}re back online."
                : error.localizedDescription)
            return
        }
        let local = try? progressStore.progress(chapterId: chapter.chapterId)
        let server = await serverProgress()
        startPage = ProgressSyncPolicy.startPage(local: local, server: server, pages: pageCount)
        currentPage = startPage
        recorder.start(at: startPage)
        state = .ready
        prefetch(around: startPage)
        requestText(around: startPage)
    }

    /// Server progress, giving up quickly so a bad connection doesn't block reading.
    private func serverProgress() async -> KavitaServerProgress? {
        let pages = pages
        let chapterId = chapter.chapterId
        return await withTaskGroup(of: KavitaServerProgress?.self) { group in
            group.addTask { try? await pages.serverProgress(chapterId: chapterId) }
            group.addTask {
                try? await Task.sleep(for: .seconds(4))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// Where reading time and pages go for the Stats tab (set by the app).
    public var activity: ActivityLog?
    @ObservationIgnored private var lastShown: Int?

    /// The page to keep on screen when the spreads change (or the pager is rebuilt).
    var pageToKeep: Int { popupPage ?? currentPage }

    /// Called as pages scroll into view. `lastVisible` is what counts as read.
    public func pagesShown(first: Int, lastVisible: Int) {
        guard state == .ready else { return }
        // Stats: a page or a spread forward counts as pages read; other moves only as time.
        if let lastShown, lastShown != lastVisible {
            let step = lastVisible - lastShown
            try? activity?.record(ActivitySubject(kind: .reading, seriesKey: String(chapter.seriesId), seriesTitle: chapter.seriesTitle,
                                                  itemKey: String(chapter.chapterId)), pages: (1...2).contains(step) ? step : 0)
        }
        lastShown = lastVisible
        currentPage = min(max(first, 0), pageCount - 1)
        if let popupPage, !(first...max(first, lastVisible)).contains(popupPage) { self.popupPage = nil }
        recorder.record(page: min(max(lastVisible, 0), pageCount - 1))
        prefetch(around: lastVisible)
        requestText(around: currentPage, through: lastVisible)
    }

    /// The end-of-chapter screen counts as finishing the last page.
    public func reachedEnd() {
        pagesShown(first: pageCount - 1, lastVisible: pageCount - 1)
    }

    /// Requested page for the paged/strip views to scroll to (from the scrubber).
    public private(set) var jumpTarget: Int?

    public func jump(to page: Int) {
        jumpTarget = min(max(page, 0), pageCount - 1)
    }

    public func consumeJump() -> Int? {
        defer { jumpTarget = nil }
        return jumpTarget
    }

    public func flushProgress() {
        recorder.flush()
        ocrTask?.cancel()
    }

    private func prefetch(around page: Int) {
        let window = (page - 1)...(page + 4)
        let wanted = window.filter { $0 >= 0 && $0 < pageCount }
        let chapterId = chapter.chapterId
        Task { await pages.prefetch(chapterId: chapterId, pages: wanted) }
    }

    // MARK: OCR and lookup

    /// OCRs the visible pages, then `ocrAhead` more, one at a time in the background.
    func requestText(around first: Int, through last: Int? = nil) {
        guard let ocr, lookup != nil else { return }
        let end = min((last ?? first) + settings.ocrAhead, pageCount - 1)
        let wanted = Array(max(first, 0)...max(end, max(first, 0))).filter { pageText[$0] == nil }
        guard !wanted.isEmpty else { return }
        ocrTask?.cancel()
        let chapterId = chapter.chapterId
        let pages = pages
        ocrTask = Task { [weak self] in
            guard await ocr.modelsInstalled else {
                self?.ocrMessage = "Download the OCR models in Settings → OCR to tap words on pages."
                return
            }
            for page in wanted {
                if Task.isCancelled { return }
                if let cached = await ocr.cachedPage(chapterId: chapterId, page: page) {
                    self?.pageText[page] = cached
                    continue
                }
                do {
                    let data = try await pages.pageData(chapterId: chapterId, page: page)
                    let result = try await ocr.page(chapterId: chapterId, page: page, imageData: data)
                    self?.pageText[page] = result.page
                    self?.ocrMessage = nil
                } catch is CancellationError {
                    return
                } catch {
                    self?.ocrMessage = error.localizedDescription
                }
            }
        }
    }

    /// Looks up the tapped character of an OCR block and shows the popup at `anchor`.
    public func lookUp(_ block: OCRBlock, page: Int, characterIndex: Int, anchor: CGRect) {
        guard let lookup else { return }
        // With the controls showing, a tap only hides them (as in the book reader).
        if showsChrome {
            showsChrome = false
            return
        }
        let offset = String(block.text.prefix(characterIndex)).utf16.count
        let started = ContinuousClock.now
        Task {
            let result = await lookup.lookup(text: block.text, utf16Offset: offset, showSource: true)
            lastTimings = LookupTimings(ocr: nil, lookup: ContinuousClock.now - started)
            popupAnchor = anchor
            popupPage = page
            popup = LookupPopupModel(page: result, context: miningContext(page: page))
        }
    }

    /// Cards mined from `page` get the page as their picture and the chapter as their source.
    func miningContext(page: Int) -> MangaMiningContext {
        MangaMiningContext(pages: pages, chapterId: chapter.chapterId, page: page,
                           miscInfo: MangaMiningContext.miscInfo(chapter: chapter, page: page),
                           seriesKey: String(chapter.seriesId), seriesTitle: chapter.seriesTitle)
    }

    func beginSelecting() {
        guard ocr != nil, lookup != nil else { return }
        isSelecting = true
    }

    func cancelSelecting() {
        isSelecting = false
        selection = nil
    }

    /// OCRs the drawn box (if it's big enough) and clears it.
    func finishSelection(pageSize size: CGSize, anchorOrigin: CGPoint) {
        isSelecting = false
        guard let (page, rect) = selection else {
            showMessage("Drag a box over the text on a page.")
            return
        }
        selection = nil
        guard rect.width > 8, rect.height > 8, size.width > 0, size.height > 0 else {
            showMessage("Drag a bigger box over the text.")
            return
        }
        let normalized = NormalizedRect(
            x: rect.minX / size.width, y: rect.minY / size.height,
            width: rect.width / size.width, height: rect.height / size.height
        )
        recognize(region: normalized, page: page, anchor: rect.offsetBy(dx: anchorOrigin.x, dy: anchorOrigin.y))
    }

    /// OCRs a region the reader drew on `page` and looks up its first word.
    public func recognize(region: NormalizedRect, page: Int, anchor: CGRect) {
        guard let ocr, let lookup else { return }
        let chapterId = chapter.chapterId
        let pages = pages
        Task {
            let started = ContinuousClock.now
            do {
                let data = try await pages.pageData(chapterId: chapterId, page: page)
                let block = try await ocr.recognize(region: region, imageData: data)
                let ocrTime = ContinuousClock.now - started
                guard !block.text.isEmpty else {
                    showMessage("No text found in that area.")
                    return
                }
                let lookupStart = ContinuousClock.now
                let result = await lookup.lookup(text: block.text, utf16Offset: 0, showSource: true)
                lastTimings = LookupTimings(ocr: ocrTime, lookup: ContinuousClock.now - lookupStart)
                popupAnchor = anchor
                popupPage = page
                popup = LookupPopupModel(page: result, context: miningContext(page: page))
            } catch {
                showMessage(error.localizedDescription)
            }
        }
    }

    /// A short-lived message (manual OCR results that didn't open a popup).
    public private(set) var toast: String?
    private var toastTask: Task<Void, Never>?

    func showMessage(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { self?.toast = nil }
        }
    }

    public func saveSettingsAsDefault() {
        try? settingsStore.saveAsDefault(settings)
    }
}

/// The page picture and source for cards mined in the manga reader.
struct MangaMiningContext: MiningContext {
    let pages: MangaPageRepository
    let chapterId: Int
    let page: Int
    let miscInfo: String
    var seriesKey: String?
    var seriesTitle: String?

    func pictureData() async -> Data? {
        try? await pages.pageData(chapterId: chapterId, page: page)
    }

    /// "Series — Chapter, p. 12" (pages are counted from 1, as the reader shows them).
    static func miscInfo(chapter: ReaderChapter, page: Int) -> String {
        let title = chapter.title.trimmingCharacters(in: .whitespaces)
        let parts = [chapter.seriesTitle, title].filter { !$0.isEmpty }
        return parts.joined(separator: " — ") + ", p. \(page + 1)"
    }
}
