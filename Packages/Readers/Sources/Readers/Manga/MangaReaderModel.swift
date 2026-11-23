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
    /// Set by the app when it offers more than the series' next (reading in a reading list).
    public var nextOffer: NextOffer?
    public let pages: MangaPageRepository
    public private(set) var state = LoadState.loading
    public private(set) var dimensions: [KavitaPageDimension] = []
    /// Lowest page index on screen.
    public private(set) var currentPage = 0
    public private(set) var startPage = 0
    public var showsChrome = false {
        // The controls came up: a word the pointer rests on isn't looked up (a click would only
        // hide them).
        didSet {
            if showsChrome { dropHover() }
            autoScroll.set(.controls, showsChrome)
            autoScroll.noteInput()
        }
    }
    /// Set by the view from the available space when spreads are on `auto`.
    public var spreadsFitScreen = false
    /// Set by the view: the reader is taller than wide, so a wide page is split (when on).
    public var viewportIsPortrait = false
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
    public var popup: LookupPopupModel? {
        didSet {
            autoScroll.set(.lookup, popup != nil)
            if popup != nil { autoScroll.noteInput() }
        }
    }
    /// Auto-scroll in the long strip.
    public let autoScroll = AutoScroll()
    /// The page of the last lookup, until you page away from it: a spread that splits (folding
    /// the iPhone Duo, which also closes the popup) shows that page rather than the spread's first.
    public private(set) var popupPage: Int?
    public private(set) var popupAnchor: CGRect = .zero
    public private(set) var lastTimings: LookupTimings?
    public private(set) var ocrMessage: String?
    /// The box being drawn for manual OCR, in the page's own coordinates.
    public var selection: (page: Int, rect: CGRect)?
    /// True from a long press until a box is drawn or selection is cancelled.
    public private(set) var isSelecting = false {
        didSet { autoScroll.set(.selecting, isSelecting) }
    }

    public let ocr: OCRService?
    public let lookup: LookupService?
    /// Page bookmarks on Kavita; nil without a Kavita account.
    public var bookmarks: PageBookmarks?
    /// Opens at this page instead of the reading position (a bookmark picked in the series).
    public var opensAt: Int?
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

    public var usesSpreads: Bool { Self.usesSpreads(settings: settings, spreadsFitScreen: spreadsFitScreen) }

    nonisolated static func usesSpreads(settings: MangaReaderSettings, spreadsFitScreen: Bool) -> Bool {
        switch settings.spreads {
        case .on: true
        case .off: false
        case .auto: spreadsFitScreen
        }
    }

    /// What the paged reader shows per swipe: a page, a spread, or half of a wide page (split
    /// in a portrait reader, by the series' Split Wide Pages).
    public var slots: [ReaderSlot] {
        SpreadLayout.readerSlots(
            pageCount: pageCount,
            widePages: widePages,
            spreads: usesSpreads,
            coverAlone: settings.coverAlone,
            splitsWide: Self.splitsWide(settings: settings, portrait: viewportIsPortrait, spreadsFitScreen: spreadsFitScreen)
        )
    }

    /// Whether a wide page is split: the setting on, the reader taller than wide, and spreads not
    /// in use (pages side by side at half width there, a split wide page would be twice their
    /// scale; Automatic never uses them in portrait).
    nonisolated static func splitsWide(settings: MangaReaderSettings, portrait: Bool, spreadsFitScreen: Bool) -> Bool {
        settings.splitsWidePages && portrait && !usesSpreads(settings: settings, spreadsFitScreen: spreadsFitScreen)
    }

    /// Kavita's wide pages (two-page scans).
    var widePages: Set<Int> {
        var wide = Set(dimensions.filter(\.isWide).map(\.pageNumber))
        #if DEBUG
        // UI tests: UITEST_WIDE_PAGES=3,5 treats those pages as wide (no wide page on the test account).
        if let listed = ProcessInfo.processInfo.environment["UITEST_WIDE_PAGES"] {
            wide.formUnion(listed.split(separator: ",").compactMap { Int($0) })
        }
        #endif
        return wide
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
        startPage = opensAt.map { min(max($0, 0), max(pageCount - 1, 0)) }
            ?? ProgressSyncPolicy.startPage(local: local, server: server, pages: pageCount, unsent: recorder.queuedChangeStillGoes(server: server))
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
    /// Daily goals: the reader says once a day when today's is reached (quietly).
    public var goals: DailyGoalStore?

    private func noteGoalReached() {
        guard let goals, let activity, goals.reachedTodayFirstTime(kind: .reading, log: activity) else { return }
        showMessage("Daily goal reached")
    }
    @ObservationIgnored private var lastShown: Int?

    /// The page to keep on screen when the spreads change (or the pager is rebuilt).
    var pageToKeep: Int { popupPage ?? currentPage }

    /// The other half of a split page came into view: a lookup on the half left behind closes
    /// (the word is no longer on screen; a page move leaves the popup open and only drops its page).
    public func halfChanged() {
        popup = nil
        popupPage = nil
        dropHover()
    }

    /// Called as pages scroll into view. `lastVisible` is what counts as read.
    public func pagesShown(first: Int, lastVisible: Int) {
        guard state == .ready else { return }
        // Stats: a page or a spread forward counts as pages read; other moves only as time.
        if let lastShown, lastShown != lastVisible {
            let step = lastVisible - lastShown
            try? activity?.record(ActivitySubject(kind: .reading, seriesKey: String(chapter.seriesId), seriesTitle: chapter.seriesTitle,
                                                  itemKey: String(chapter.chapterId)), pages: (1...2).contains(step) ? step : 0)
            noteGoalReached()
        }
        lastShown = lastVisible
        currentPage = min(max(first, 0), pageCount - 1)
        if let popupPage, !(first...max(first, lastVisible)).contains(popupPage) { self.popupPage = nil }
        // A turn by key or swipe leaves the pointer where it was, over a page no longer shown.
        if let hovered, !Self.hoverStays(onPage: hovered.page, first: first, lastVisible: lastVisible) { dropHover() }
        recorder.record(page: min(max(lastVisible, 0), pageCount - 1))
        prefetch(around: lastVisible)
        requestText(around: currentPage, through: lastVisible)
    }

    /// The end-of-chapter screen counts as finishing the last page.
    public func reachedEnd() {
        // Auto-scroll stops at the chapter's end (the next chapter is the reader's choice).
        autoScroll.stop()
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
            lookupBlock = (page, block)
            popup = LookupPopupModel(page: result, context: miningContext(page: page))
        }
    }

    // MARK: Look Up on Hover (Mac)

    /// The character the pointer rests on (Settings ▸ Popup ▸ Look Up on Hover).
    @ObservationIgnored private var hovered: (page: Int, block: OCRBlock, index: Int, anchor: CGRect)?
    @ObservationIgnored private var hoverTask: Task<Void, Never>?

    /// The pointer moved onto a character of a block's lettering.
    public func hovered(_ block: OCRBlock, page: Int, characterIndex: Int, anchor: CGRect) {
        if let hovered, hovered.page == page, hovered.block == block, hovered.index == characterIndex { return }
        hovered = (page, block, characterIndex, anchor)
        lookUpHovered()
    }

    /// The pointer left a block's lettering.
    public func hoverEnded(_ block: OCRBlock, page: Int) {
        guard let hovered, hovered.page == page, hovered.block == block else { return }
        self.hovered = nil
        hoverTask?.cancel()
    }

    /// Looks up the word under the pointer when Look Up on Hover allows it (its key is held, or
    /// no key is needed), as a click there would. A short rest first, so the pointer crossing a
    /// bubble on its way elsewhere looks nothing up. Also called when a key is pressed.
    public func lookUpHovered() {
        hoverTask?.cancel()
        #if os(macOS)
        guard let hovered, let setting = lookup?.popupSettings.hoverLookup, HoverModifiers.shared.allows(setting) else { return }
        let marked = textOverlay(page: hovered.page).flatMap { $0.block == hovered.block ? $0.highlight : nil }
        guard Self.hoverLooksUp(hovered.block.text, at: hovered.index, marked: marked, controlsShowing: showsChrome) else { return }
        hoverTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(setting == .always ? 180 : 60))
            guard !Task.isCancelled, let self, let now = self.hovered,
                  now.page == hovered.page, now.block == hovered.block, now.index == hovered.index else { return }
            self.lookUp(hovered.block, page: hovered.page, characterIndex: hovered.index, anchor: hovered.anchor)
        }
        #endif
    }

    /// Forgets the character the pointer rested on (its block is no longer where it was).
    private func dropHover() {
        hovered = nil
        hoverTask?.cancel()
    }

    /// Whether a rested-on character's page is still among those shown.
    nonisolated static func hoverStays(onPage page: Int, first: Int, lastVisible: Int) -> Bool {
        (first...max(first, lastVisible)).contains(page)
    }

    /// Whether resting on character `index` of a block's text looks it up: a character of a word
    /// (not punctuation or a space), not one of the word already marked, and not while the
    /// controls show (a click then only hides them).
    nonisolated static func hoverLooksUp(_ text: String, at index: Int, marked: Range<Int>?, controlsShowing: Bool) -> Bool {
        guard !controlsShowing, marked?.contains(index) != true, let character = text.dropFirst(index).first else { return false }
        return !character.isWhitespace && !character.isPunctuation && !character.isSymbol
    }

    /// The block whose word is being looked up (the word is marked on its lettering).
    @ObservationIgnored private var lookupBlock: (page: Int, block: OCRBlock)?

    /// While the popup is open: the block the word is in, and which of its characters the word
    /// showing covers (it follows taps in the popup's sentence too), to mark on the page.
    public func textOverlay(page: Int) -> (block: OCRBlock, highlight: Range<Int>?)? {
        guard settings.showsTextOverlay, let popup, let lookupBlock, lookupBlock.page == page else { return nil }
        let text = lookupBlock.block.text
        let source = popup.pages.last { $0.source?.text == text }?.source
        let range = source.map { source -> Range<Int> in
            let start = text.distance(from: text.startIndex, to: String.Index(utf16Offset: min(source.utf16Offset, text.utf16.count), in: text))
            let end = text.distance(from: text.startIndex,
                                    to: String.Index(utf16Offset: min(source.utf16Offset + source.utf16Length, text.utf16.count), in: text))
            return start..<max(start, end)
        }
        return (lookupBlock.block, range)
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
