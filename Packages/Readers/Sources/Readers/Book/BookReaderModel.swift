import Core
import CoreGraphics
import Dictionary
import Foundation
import KavitaKit
import Lookup
import Observation

/// One EPUB volume from Kavita. Kavita's page N is the book's spine item N, and
/// the position inside it is Kavita's `bookScrollId` (an XPath into that item).
@MainActor @Observable
public final class BookReaderModel {
    public enum LoadState: Equatable {
        case loading
        case ready
        case failed(String)
    }

    public let chapter: ReaderChapter
    public let nextChapter: ReaderChapter?
    public private(set) var state = LoadState.loading
    public private(set) var package: EpubPackage?
    /// The spine item on screen (Kavita's page).
    public private(set) var spineIndex = 0
    /// Page within the section, and how many it has.
    public private(set) var sectionPage = 0
    public private(set) var sectionPages = 1
    public private(set) var isVertical = true
    /// Characters read so far and in the whole book.
    public private(set) var charactersRead = 0
    public private(set) var totalCharacters = 0
    private var textIndex = BookTextIndex(sections: [])
    /// The screen's safe area (set by the view), added to the page margins.
    public var safeAreaInsets = EdgeInsetsValue() {
        didSet { if oldValue != safeAreaInsets, state == .ready { updatePageSettings() } }
    }
    @ObservationIgnored private var insetScreen: CGSize = .zero

    /// The safe area as the view reports it. Hiding the status bar with the controls gives back
    /// its inset on some screens (iPad, older iPhones); keeping the larger inset until the screen
    /// itself changes (rotation, a window resize) stops the text moving a column each time.
    public func setSafeArea(_ new: EdgeInsetsValue, size: CGSize) {
        let screen = CGSize(width: size.width + new.leading + new.trailing, height: size.height + new.top + new.bottom)
        guard screen == insetScreen else {
            insetScreen = screen
            safeAreaInsets = new
            return
        }
        // The iPhone Duo's folded screen keeps its clock in a column at the side, and showing the
        // status bar adds a top inset the text doesn't need: there the smaller top stays, so the
        // page keeps the size facing pages copy (`SpreadFrames`).
        let sideColumn = screen.height > screen.width && max(new.leading, new.trailing) >= 60
        safeAreaInsets = EdgeInsetsValue(top: sideColumn ? min(new.top, safeAreaInsets.top) : max(new.top, safeAreaInsets.top),
                                         leading: max(new.leading, safeAreaInsets.leading),
                                         bottom: max(new.bottom, safeAreaInsets.bottom), trailing: max(new.trailing, safeAreaInsets.trailing))
    }

    public var progressFraction: Double {
        totalCharacters > 0 ? min(Double(charactersRead) / Double(totalCharacters), 1) : 0
    }
    public var showsChrome = false
    public var settings: BookReaderSettings {
        didSet {
            guard settings != oldValue else { return }
            try? settingsStore.save(settings, seriesId: chapter.seriesId)
            if state == .ready {
                web?.setScrollEnabled(settings.layout == .scroll)
                updatePageSettings()
            }
        }
    }
    /// Light or dark, for the system theme (set by the view).
    public var prefersDark = false {
        didSet { if oldValue != prefersDark, settings.theme == .system, state == .ready { updatePageSettings() } }
    }

    /// UI tests only: when set, each section is audited for cut or repeated characters
    /// once laid out, and the results collect here.
    public var auditsPages = false
    public private(set) var auditResults: [String] = []

    /// Where reading time and characters go for the Stats tab (set by the app).
    public var activity: ActivityLog?
    /// Where each opened volume's count is kept for the library's progress (set by the app).
    public var lengths: BookLengths?
    /// More characters than a page holds in one move is a jump, not reading.
    static let pageCharacterLimit = 2500

    public var popup: LookupPopupModel? {
        didSet {
            if popup == nil {
                web?.clearHighlight()
                companion?.clearHighlight()
                if oldValue != nil { readAlong?.lookupClosed() }
            }
        }
    }
    public private(set) var popupAnchor: CGRect = .zero
    public private(set) var toast: String?

    public let lookup: LookupService?
    let repository: BookRepository
    private let settingsStore: BookReaderSettingsStore
    private let progressStore: ReadingProgressStore
    private let recorder: ReadingProgressRecorder
    private let serverProgress: @Sendable (Int) async throws -> KavitaServerProgress
    private let chapterCover: @Sendable (Int) async -> Data?
    private(set) var web: BookWebController?
    private var folder: URL?
    private var toastTask: Task<Void, Never>?
    /// Set once the reader moves (page turn, swipe, contents, link). Until then positions
    /// come from opening and re-layout (settings, safe area), which isn't reading and
    /// mustn't overwrite progress — e.g. reopening a finished volume at its cover.
    private var hasMoved = false

    public init(
        chapter: ReaderChapter,
        nextChapter: ReaderChapter?,
        repository: BookRepository,
        settingsStore: BookReaderSettingsStore,
        progressStore: ReadingProgressStore,
        outbox: OutboxStore,
        lookup: LookupService?,
        serverProgress: @escaping @Sendable (Int) async throws -> KavitaServerProgress,
        chapterCover: @escaping @Sendable (Int) async -> Data? = { _ in nil },
        syncNow: @escaping @MainActor () -> Void
    ) {
        self.chapter = chapter
        self.nextChapter = nextChapter
        self.repository = repository
        self.settingsStore = settingsStore
        self.progressStore = progressStore
        self.lookup = lookup
        self.serverProgress = serverProgress
        self.chapterCover = chapterCover
        recorder = ReadingProgressRecorder(chapter: chapter, progressStore: progressStore, outbox: outbox, syncNow: syncNow)
        settings = (try? settingsStore.settings(seriesId: chapter.seriesId)) ?? .default
    }

    public var sectionCount: Int { package?.spine.count ?? chapter.pages }

    /// Page order for gestures and the slider: the book's own setting (`rtl` in the spine),
    /// or vertical text when the book doesn't say. A cover page may be horizontal in a vertical book.
    public var readsRightToLeft: Bool {
        (package?.pageProgressionRTL ?? false) || isVertical
    }

    /// The table-of-contents entry for the section on screen.
    public var currentSectionTitle: String? {
        package?.toc.last { $0.spineIndex <= spineIndex }?.title
    }

    // MARK: Loading

    public func load() async {
        state = .loading
        do {
            let book = try await repository.book(chapterId: chapter.chapterId)
            package = book.package
            folder = book.folder
            let package = book.package, folder = book.folder
            textIndex = await Task.detached { BookTextIndex.load(folder: folder, package: package) }.value
            totalCharacters = textIndex.total
            try? lengths?.save(BookLength(chapterId: chapter.chapterId, seriesId: chapter.seriesId, sections: textIndex.sections,
                                          kavitaWordCount: nil, kavitaPages: chapter.pages, countedAt: .now))
            updateReadingSpeed()
            let controller = BookWebController(folder: book.folder)
            controller.onEvent = { [weak self] event in self?.handle(event) }
            controller.setScrollEnabled(settings.layout == .scroll)
            web = controller
        } catch {
            state = .failed(error.localizedDescription)
            return
        }
        let local = try? progressStore.progress(chapterId: chapter.chapterId)
        let server = await quickServerProgress()
        let start = ProgressSyncPolicy.startPosition(local: local, server: server, pages: sectionCount)
        recorder.start(at: start.page, scrollId: start.scrollId)
        state = .ready
        open(section: start.page, at: Self.startPlace(start, local: local, index: textIndex))
    }

    /// Server progress, giving up quickly so a bad connection doesn't block reading.
    private func quickServerProgress() async -> KavitaServerProgress? {
        let fetch = serverProgress
        let chapterId = chapter.chapterId
        return await withTaskGroup(of: KavitaServerProgress?.self) { group in
            group.addTask { try? await fetch(chapterId) }
            group.addTask {
                try? await Task.sleep(for: .seconds(4))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    enum Position {
        case start, end
        case xpath(String)
        case fragment(String)
        /// This device's own place: a fraction of the section's characters (exact in paged
        /// layouts, where a page can start inside a paragraph), the xpath for scrolling.
        case place(xpath: String?, fraction: Double)

        var script: String {
            switch self {
            case .start: "'start'"
            case .end: "'end'"
            case .xpath(let path): "{xpath: \(BookWebController.jsString(path))}"
            case .fragment(let id): "{fragment: \(BookWebController.jsString(id))}"
            case let .place(xpath, fraction): "{xpath: \(BookWebController.jsString(xpath ?? "")), fraction: \(fraction)}"
            }
        }
    }

    /// Where to open: this device's exact place when its progress is the one chosen (it keeps
    /// the characters read), else Kavita's position in the section.
    static func startPlace(_ start: (page: Int, scrollId: String?), local: LocalReadingProgress?, index: BookTextIndex) -> Position {
        if let local, local.page == start.page, local.scrollId == start.scrollId, let characters = local.characters,
           index.sections.indices.contains(start.page), index.sections[start.page] > 0 {
            let within = characters - index.start(of: start.page)
            if within >= 0 { return .place(xpath: start.scrollId, fraction: min(Double(within) / Double(index.sections[start.page]), 1)) }
        }
        return start.scrollId.map { .xpath($0) } ?? .start
    }

    func open(section: Int, at position: Position) {
        guard let package, let web, package.spine.indices.contains(section),
              let url = BookSchemeHandler.url(chapterId: chapter.chapterId, path: package.spine[section].path) else { return }
        spineIndex = section
        web.load(url, settings: jsSettings, at: position.script)
    }

    var jsSettings: [String: Any] {
        let theme = settings.theme == .system ? (prefersDark ? "dark" : "light") : settings.theme.rawValue
        // "As in book" for right-to-left books means vertical throughout, even where a
        // section (like a horizontal contents page) says otherwise. Picture pages stay as they are.
        let writingMode = settings.writingMode == .auto && package?.pageProgressionRTL == true ? "vertical" : settings.writingMode.rawValue
        // The bar runs along the screen's bottom edge, inside the text's margin. Always-on
        // progress text sits just above it, in the bottom inset where that's tall enough
        // (iPhone, iPad); the Mac's window has none, so the text keeps a little more room.
        let barRoom: Double = 0
        let textRoom: Double = settings.progressText == .always ? max(0, 32 - safeAreaInsets.bottom - 20) : 0
        // Facing pages sit clear of the screen's edges already: each is the folded screen's safe area.
        let insets = spread ? EdgeInsetsValue() : safeAreaInsets
        return [
            "layout": settings.layout.rawValue, "writingMode": writingMode, "spread": spread,
            "insets": ["top": insets.top, "right": insets.trailing,
                       "bottom": insets.bottom + barRoom + textRoom, "left": insets.leading],
            "fontSize": settings.fontSize, "lineHeight": settings.lineHeight, "margin": settings.margin,
            "theme": theme, "font": settings.font.rawValue, "rtl": package?.pageProgressionRTL ?? false,
            "furigana": settings.furigana.rawValue,
        ]
    }

    // MARK: Navigation

    public func nextPage() {
        hasMoved = true
        readAlong?.userTurnedPage()
        web?.run("window.bookReader?.next()")
    }

    public func previousPage() {
        hasMoved = true
        readAlong?.userTurnedPage()
        web?.run("window.bookReader?.previous()")
    }

    public func goToSection(_ index: Int) {
        hasMoved = true
        open(section: index, at: .start)
    }

    public func go(to entry: EpubPackage.TOCEntry) {
        hasMoved = true
        open(section: entry.spineIndex, at: entry.fragment.map { .fragment($0) } ?? .start)
    }

    // MARK: Facing pages

    /// Two pages side by side, the screen folded down the middle (set by the view). This page is
    /// the one read first; `companion` shows the next, or nothing after a section's last page.
    public var spread = false {
        didSet {
            guard spread != oldValue else { return }
            if spread, companion == nil, let folder {
                let controller = BookWebController(folder: folder)
                controller.onEvent = { [weak self] event in self?.handleCompanion(event) }
                controller.setScrollEnabled(false)
                companion = controller
            } else if !spread {
                companion = nil
                companionSection = nil
            }
            if state == .ready { updatePageSettings() }
        }
    }
    /// The facing page's web view, while `spread`.
    private(set) var companion: BookWebController?
    /// The section the facing page has loaded.
    private var companionSection: Int?
    /// The lookup's word is on the facing page (the popup then covers this one).
    public private(set) var popupOnCompanion = false
    /// Both pages' frames in the reader (set by the view), for the tap zones.
    public var spreadFrames: (first: CGRect, second: CGRect)?

    private var companionSettings: [String: Any] {
        jsSettings.merging(["spread": false, "companion": true]) { $1 }
    }

    private func updatePageSettings() {
        web?.update(settings: jsSettings)
        companion?.update(settings: companionSettings)
    }

    /// Shows the page after this one on the facing page (loading the section there first).
    private func syncCompanion() {
        guard spread, settings.layout == .paged, let companion, let package, package.spine.indices.contains(spineIndex),
              let url = BookSchemeHandler.url(chapterId: chapter.chapterId, path: package.spine[spineIndex].path) else { return }
        let index = sectionPage + 1
        if companionSection != spineIndex {
            companionSection = spineIndex
            companion.load(url, settings: companionSettings, at: "{follow: \(index)}")
        } else {
            companion.run("window.bookReader?.follow(\(index))")
        }
    }

    func handleCompanion(_ event: BookWebEvent) {
        switch event {
        case let .tap(text, offset, rect):
            lookUp(text: text, offset: offset, rect: rect, onCompanion: true)
        case .miss(let point):
            tapOutsideText(at: point, onCompanion: true)
        case .swipe, .link:
            handle(event)
        case .ready:
            // Caught up with this page (it may have turned while the section loaded), and once
            // more a moment later: just opened, its first placing could land on a later page.
            companion?.run("window.bookReader?.follow(\(sectionPage + 1))")
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                guard let self, spread else { return }
                companion?.run("window.bookReader?.follow(\(sectionPage + 1))")
            }
            Task { await markWords() }
            if let cue = readAlongCue, cue.section == spineIndex {
                companion?.run("window.bookReader?.readAlong.show(\(cue.run), \(cue.offset), \(cue.length), false)")
            }
        case let .position(page, pages, _, _, _, _, _):
            // The facing page must be the one after this page, with the same page breaks: when
            // it isn't (laid out at another size, or a turn it missed), ask again, a few times.
            let wanted = sectionPage + 1
            guard companionSection == spineIndex, wanted < sectionPages, page != wanted || pages != sectionPages,
                  companionRetries < 3 else { return }
            companionRetries += 1
            if pages != sectionPages {
                companion?.update(settings: companionSettings)
            } else {
                companion?.run("window.bookReader?.follow(\(wanted))")
            }
        case .edge, .userScrolled, .failed:
            break
        }
    }

    /// Corrections sent to the facing page since this page last moved.
    private var companionRetries = 0

    /// The forward edge of the last section: the next volume, if there is one.
    public private(set) var reachedEnd = false

    func handle(_ event: BookWebEvent) {
        switch event {
        case let .position(page, pages, xpath, vertical, characters, sectionCharacters, moved):
            if moved { hasMoved = true }
            let readBefore = charactersRead
            sectionPage = page
            sectionPages = max(pages, 1)
            isVertical = vertical
            // The page's count of this section, scaled to the precomputed one (they can differ
            // slightly; contents pages count as nothing).
            let indexed = textIndex.sections.indices.contains(spineIndex) ? textIndex.sections[spineIndex] : sectionCharacters
            let within = sectionCharacters > 0 && indexed > 0 ? Int(Double(characters) / Double(sectionCharacters) * Double(indexed)) : 0
            charactersRead = page == pages - 1 && spineIndex == sectionCount - 1 ? totalCharacters : textIndex.start(of: spineIndex) + within
            reachedEnd = false
            companionRetries = 0
            syncCompanion()
            if hasMoved {
                recorder.record(page: spineIndex, scrollId: xpath.isEmpty ? nil : xpath, characters: charactersRead)
                // Stats: characters gained by paging on; a jump (contents, a link) counts only as time.
                let gained = charactersRead - readBefore
                try? activity?.record(ActivitySubject(kind: .reading, seriesKey: String(chapter.seriesId), seriesTitle: chapter.seriesTitle,
                                                      itemKey: String(chapter.chapterId)),
                                      characters: (1...Self.pageCharacterLimit).contains(gained) ? gained : 0)
            }
        case .edge(let forward):
            hasMoved = true
            if forward {
                if spineIndex + 1 < sectionCount {
                    open(section: spineIndex + 1, at: .start)
                } else {
                    // Reading the last page marks the volume read in Kavita.
                    recorder.record(page: sectionCount - 1, scrollId: nil, characters: totalCharacters)
                    reachedEnd = true
                    showsChrome = true
                }
            } else if spineIndex > 0 {
                open(section: spineIndex - 1, at: .end)
            }
        case let .tap(text, offset, rect):
            lookUp(text: text, offset: offset, rect: rect)
        case .miss(let point):
            tapOutsideText(at: point)
        case .swipe(let right):
            // Right-to-left (vertical) books go forward with a swipe to the right.
            guard settings.layout == .paged, popup == nil else { return }
            right == readsRightToLeft ? nextPage() : previousPage()
        case .userScrolled:
            readAlong?.userTurnedPage()
        case let .link(path, fragment):
            hasMoved = true
            if let index = package?.spine.firstIndex(where: { $0.path == path }) {
                open(section: index, at: fragment.map { .fragment($0) } ?? .start)
            }
        case .ready:
            Task { await markWords() }
            // Read-along: the cue waiting for this section, or the current one shown again.
            if let pending = pendingReadAlong, pending.cue.section == spineIndex {
                pendingReadAlong = nil
                showReadAlong(pending.cue, follow: pending.follow)
            } else if let cue = readAlongCue, cue.section == spineIndex {
                showReadAlong(cue, follow: false)
            }
            if auditsPages, let web {
                let section = spineIndex
                Task {
                    let result = await web.evaluate("window.bookReader.audit()") as? String ?? "no result"
                    auditResults.append("s\(section) \(result)")
                }
            }
        case .failed(let message):
            showMessage(message)
        }
    }

    /// The screen width, set by the view, for tap zones.
    public var viewSize: CGSize = .zero

    /// Edges turn pages (the left edge goes forward in right-to-left books); the middle shows the controls.
    func tapOutsideText(at point: CGPoint, onCompanion: Bool = false) {
        let origin = spread ? (onCompanion ? spreadFrames?.second.minX : spreadFrames?.first.minX) ?? 0 : 0
        tapZone(x: point.x + origin)
    }

    /// A tap at `x` across the reader (facing pages: their margins and the crease too).
    func tapZone(x: CGFloat) {
        if popup != nil {
            // Facing pages show the lookup as a panel, not a popover that closes itself.
            if spread { popup = nil }
            return
        }
        let zone = x / max(viewSize.width, 1)
        // Facing pages: only the outer edges turn, so the middle of either page shows the controls.
        let edge = spread ? 0.12 : 0.25
        if zone < edge {
            readsRightToLeft ? nextPage() : previousPage()
        } else if zone > 1 - edge {
            readsRightToLeft ? previousPage() : nextPage()
        } else {
            showsChrome.toggle()
        }
    }

    // MARK: Lookup

    func lookUp(text: String, offset: Int, rect: CGRect, onCompanion: Bool = false) {
        guard let lookup, let source = onCompanion ? companion : web else { return }
        // With the controls showing, a tap only hides them: the bar covers the tops of the
        // columns, so the word under the finger may be half hidden. The next tap looks up.
        if showsChrome {
            showsChrome = false
            return
        }
        Task {
            // Read the tap's place in the runs first: the lookup highlight splits text nodes.
            let place = readAlong == nil ? nil : await tapPlace(in: source)
            let page = await lookup.lookup(text: text, utf16Offset: offset)
            guard let length = page.results.first?.matched.utf16.count, length > 0 else { return }
            web?.clearHighlight()
            companion?.clearHighlight()
            source.highlight(offset: offset, length: length)
            popupAnchor = rect
            popupOnCompanion = onCompanion
            var context = miningContext()
            if let place, let readAlong {
                readAlong.lookupOpened(section: place.section, run: place.run, offset: place.offset)
                context.sentenceClip = readAlong.sentenceAudio(section: place.section, run: place.run, offset: place.offset)
            }
            popup = LookupPopupModel(page: page, context: context)
        }
    }

    // MARK: Read-along

    /// Set by the app while a paired book is read along.
    @ObservationIgnored public var readAlong: (any BookReadAlongHost)?
    /// The spoken sentence shown on the page.
    public private(set) var readAlongCue: ReadAlongCue?
    /// A cue to show once its section has loaded.
    private var pendingReadAlong: (cue: ReadAlongCue, follow: Bool)?

    /// Highlights the spoken sentence; with `follow`, turns (or opens its section) to keep it in view.
    public func showReadAlong(_ cue: ReadAlongCue?, follow: Bool) {
        readAlongCue = cue
        guard let web else { return }
        guard let cue else {
            pendingReadAlong = nil
            web.run("window.bookReader?.readAlong.clear()")
            companion?.run("window.bookReader?.readAlong.clear()")
            return
        }
        companion?.run(companionSection == cue.section
            ? "window.bookReader?.readAlong.show(\(cue.run), \(cue.offset), \(cue.length), false)"
            : "window.bookReader?.readAlong.clear()")
        if cue.section != spineIndex {
            web.run("window.bookReader?.readAlong.clear()")
            guard follow else { return }
            hasMoved = true
            pendingReadAlong = (cue, follow)
            open(section: cue.section, at: .start)
            return
        }
        web.run("window.bookReader?.readAlong.show(\(cue.run), \(cue.offset), \(cue.length), \(follow))")
    }

    /// Where the last tap landed: (section, run, UTF-16 offset).
    private func tapPlace(in source: BookWebController) async -> (section: Int, run: Int, offset: Int)? {
        guard let json = await source.evaluate("JSON.stringify(window.bookReader?.readAlong.lastTap() ?? null)") as? String,
              let value = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Int],
              let run = value["run"], let offset = value["offset"] else { return nil }
        return (spineIndex, run, offset)
    }

    /// The page on screen for listening from it: its first character (section, run, UTF-16
    /// offset), and where the next page starts in the same section (nil on its last page).
    public struct PagePlace: Equatable, Sendable {
        public var section: Int
        public var run: Int
        public var offset: Int
        public var next: (run: Int, offset: Int)?

        public static func == (a: PagePlace, b: PagePlace) -> Bool {
            (a.section, a.run, a.offset) == (b.section, b.run, b.offset) && a.next?.run == b.next?.run && a.next?.offset == b.next?.offset
        }
    }

    public func firstVisiblePlace() async -> PagePlace {
        let json = await web?.evaluate("JSON.stringify(window.bookReader?.readAlong.firstVisiblePlace() ?? null)") as? String
        // Mixed with nulls (the last page), so read the numbers one by one.
        let place = json.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] } ?? [:]
        let number = { (key: String) in (place[key] as? NSNumber)?.intValue }
        let next = number("nextRun").flatMap { run in number("nextOffset").map { (run: run, offset: $0) } }
        return PagePlace(section: spineIndex, run: number("run") ?? 0, offset: number("offset") ?? 0, next: next)
    }

    /// Opens the book at a sentence (resuming from listening elsewhere).
    public func open(at cue: ReadAlongCue) {
        showReadAlong(cue, follow: true)
        if cue.section == spineIndex { hasMoved = true }
    }

    // MARK: Word marks

    /// Each section's words, by run of text (see `BookReader.js`), split once per book.
    private var sectionWords: [Int: [[WordSpan]]] = [:]

    /// Underlines the section's words by their state in the mining deck (Settings ▸ Lookup).
    /// Call again after the states change (`MiningService.revision`); the split is reused.
    public func markWords() async {
        guard let web else { return }
        guard let lookup, let mining = lookup.mining, mining.marksWords else {
            web.run("window.bookReader?.unmarkWords()")
            companion?.run("window.bookReader?.unmarkWords()")
            return
        }
        let section = spineIndex
        let runs: [[WordSpan]]
        if let known = sectionWords[section] {
            runs = known
        } else {
            guard let texts = await web.evaluate("window.bookReader.wordRuns()") as? [String] else { return }
            runs = await BookWords.words(texts: texts, section: section, folder: folder, scanner: lookup.library.scanner)
            sectionWords[section] = runs
        }
        guard section == spineIndex else { return }
        let marks = mining.wordMarks()
        var payload: [[Any]] = []
        for (run, words) in runs.enumerated() {
            for word in words {
                switch marks.state(expression: word.expression, reading: word.reading) {
                case .notInAnki: payload.append([run, word.offset, word.length, "km-new"])
                case .learning: payload.append([run, word.offset, word.length, "km-learning"])
                case .known: break
                }
            }
        }
        let script = "window.bookReader?.markWords(\(BookWebController.json(payload)), \(BookWebController.jsString(lookup.accent?.color ?? "#0a84ff")))"
        web.run(script)
        if companionSection == section { companion?.run(script) }
    }

    func miningContext() -> BookMiningContext {
        let cover = package?.coverPath.flatMap { path in folder?.appending(path: path) }
        let chapterId = chapter.chapterId
        let fallback = chapterCover
        return BookMiningContext(
            cover: cover, fallbackCover: { await fallback(chapterId) },
            miscInfo: BookMiningContext.miscInfo(chapter: chapter, section: currentSectionTitle),
            seriesKey: String(chapter.seriesId), seriesTitle: chapter.seriesTitle
        )
    }

    public func saveSettingsAsDefault() {
        try? settingsStore.saveAsDefault(settings)
    }

    // MARK: Progress and messages

    public func flushProgress() {
        recorder.flush()
        updateReadingSpeed()
    }

    /// Characters a second from this series' reading (or all reading), for the time left.
    public private(set) var readingSpeed: Double?

    /// "~6 h left" at this reader's speed; nil until there's enough reading to estimate from.
    public var timeLeft: String? {
        readingSpeed.flatMap { ActivityLog.timeLeft(characters: totalCharacters - charactersRead, speed: $0) }
    }

    private func updateReadingSpeed() {
        readingSpeed = (try? activity?.readingSpeed(seriesKey: String(chapter.seriesId))) ?? nil
    }

    public func showMessage(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { toast = nil }
        }
    }
}

/// Safe-area insets in points (Sendable and Equatable, unlike SwiftUI's EdgeInsets on every platform).
public struct EdgeInsetsValue: Equatable, Sendable {
    public var top: Double = 0, leading: Double = 0, bottom: Double = 0, trailing: Double = 0
    public init(top: Double = 0, leading: Double = 0, bottom: Double = 0, trailing: Double = 0) {
        self.top = top
        self.leading = leading
        self.bottom = bottom
        self.trailing = trailing
    }
}

/// The cover and source for cards mined from a book.
struct BookMiningContext: MiningContext {
    let cover: URL?
    let fallbackCover: @Sendable () async -> Data?
    let miscInfo: String
    var seriesKey: String?
    var seriesTitle: String?
    /// Read-along: the tapped sentence's audio.
    var sentenceClip: (@Sendable () async -> SentenceAudio?)?

    func sentenceAudio() async -> SentenceAudio? { await sentenceClip?() }

    func pictureData() async -> Data? {
        if let cover, let data = try? Data(contentsOf: cover) { return data }
        return await fallbackCover()
    }

    /// "Series — Volume 1 · １ 空の庭へようこそ！"
    static func miscInfo(chapter: ReaderChapter, section: String?) -> String {
        let title = chapter.title.trimmingCharacters(in: .whitespaces)
        var text = [chapter.seriesTitle, title].filter { !$0.isEmpty }.joined(separator: " — ")
        if let section = section?.trimmingCharacters(in: .whitespacesAndNewlines), !section.isEmpty { text += " · " + section }
        return text
    }
}

/// What the reader asks of a read-along (Yomu's, which owns the audio).
@MainActor
public protocol BookReadAlongHost: AnyObject {
    /// A word at this place was looked up: playback pauses until the popup closes.
    func lookupOpened(section: Int, run: Int, offset: Int)
    func lookupClosed()
    /// Paging or scrolling by hand: stop following the audio until asked again.
    func userTurnedPage()
    /// The audio of the sentence at this place, for a card.
    func sentenceAudio(section: Int, run: Int, offset: Int) -> (@Sendable () async -> SentenceAudio?)?
}
