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
    /// Set by the app when it offers more than the series' next (reading in a reading list).
    public var nextOffer: NextOffer?
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
    public var showsChrome = false {
        didSet {
            autoScroll.set(.controls, showsChrome)
            autoScroll.noteInput()
        }
    }
    /// Auto-scroll in the Scroll layout.
    public let autoScroll = AutoScroll()
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
    /// Daily goals: the reader says once a day when today's is reached (quietly).
    public var goals: DailyGoalStore?

    private func noteGoalReached() {
        guard let goals, let activity, goals.reachedTodayFirstTime(kind: .reading, log: activity) else { return }
        showMessage("Daily goal reached")
    }
    /// Where each opened volume's count is kept for the library's progress (set by the app).
    public var lengths: BookLengths?
    /// More characters than a page holds in one move is a jump, not reading.
    static let pageCharacterLimit = 2500

    public var popup: LookupPopupModel? {
        didSet {
            autoScroll.set(.lookup, popup != nil)
            if popup != nil { autoScroll.noteInput() }
            if popup == nil {
                web?.clearHighlight()
                companion?.clearHighlight()
                if oldValue != nil { readAlong?.lookupClosed() }
                tappedHighlight = nil
                tappedSentence = nil
            }
        }
    }
    public private(set) var popupAnchor: CGRect = .zero
    public private(set) var toast: String?

    public let lookup: LookupService?
    /// Highlights, notes and bookmarks on Kavita; nil without a Kavita account.
    public var marks: BookMarks? {
        didSet { marks?.onChange = { [weak self] in self?.showMarks() } }
    }
    /// Opens here instead of the reading position (a bookmark or highlight picked in the series).
    public var opensAt: (page: Int, xpath: String?)?
    /// The place on screen (Kavita's XPath), for bookmarks.
    public private(set) var currentXPath: String?
    /// The highlight the looked-up word is in, while the popup is open.
    public private(set) var tappedHighlight: ReaderMark?
    /// The highlight whose note is being written.
    public var editingNote: ReaderMark?
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
            let controller = BookWebController(folder: book.folder, fonts: fonts)
            controller.onEvent = { [weak self] event in self?.handle(event) }
            controller.hoverLookup = { [weak self] in self?.lookup?.popupSettings.hoverLookup.rawValue ?? "off" }
            controller.setScrollEnabled(settings.layout == .scroll)
            web = controller
        } catch {
            state = .failed(error.localizedDescription)
            return
        }
        let local = try? progressStore.progress(chapterId: chapter.chapterId)
        let server = await quickServerProgress()
        var start = ProgressSyncPolicy.startPosition(local: local, server: server, pages: sectionCount, unsent: recorder.queuedChangeStillGoes(server: server))
        if let opensAt { start = (min(max(opensAt.page, 0), max(sectionCount - 1, 0)), opensAt.xpath) }
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
            // An added font, if it's still there (removed: the book's own).
            "customFontURL": customFontURL ?? NSNull(),
        ]
    }

    // MARK: Navigation

    public func nextPage() {
        leaveSearchPlace()
        hasMoved = true
        readAlong?.userTurnedPage()
        web?.run("window.bookReader?.next()")
    }

    public func previousPage() {
        leaveSearchPlace()
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
                let controller = BookWebController(folder: folder, fonts: fonts)
                controller.onEvent = { [weak self] event in self?.handleCompanion(event) }
                controller.hoverLookup = { [weak self] in self?.lookup?.popupSettings.hoverLookup.rawValue ?? "off" }
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
        if auditsPages { auditFont() }
    }

    /// UI tests: the font the page's text is drawn in, and whether an added font has loaded.
    private func auditFont() {
        guard let web else { return }
        Task {
            try? await Task.sleep(for: .seconds(1))
            let font = await web.evaluate("getComputedStyle(document.body).fontFamily + ' loaded=' + document.fonts.check('16px \"km-custom\"')") as? String
            auditResults.append("font \(font ?? "?")")
        }
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
            showMarks()
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
        case .edge, .userScrolled, .input, .failed:
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
            currentXPath = xpath.isEmpty ? nil : xpath
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
                noteGoalReached()
            }
        case .edge(let forward):
            hasMoved = true
            if forward {
                if spineIndex + 1 < sectionCount {
                    open(section: spineIndex + 1, at: .start)
                } else {
                    // Reading the last page marks the volume read in Kavita.
                    recorder.record(page: sectionCount - 1, scrollId: nil, characters: totalCharacters)
                    // Auto-scroll stops at the book's end (it carries on across sections).
                    autoScroll.stop()
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
            leaveSearchPlace()
            readAlong?.userTurnedPage()
            autoScroll.handScrolled()
        case .input:
            autoScroll.noteInput()
        case let .link(path, fragment):
            hasMoved = true
            if let index = package?.spine.firstIndex(where: { $0.path == path }) {
                open(section: index, at: fragment.map { .fragment($0) } ?? .start)
            }
        case .ready:
            Task { await markWords() }
            showMarks()
            // A new section loaded while auto-scrolling (it reached the last one's end): on.
            if autoScroll.isMoving { Task { await applyAutoScroll() } }
            // A search result: turn to it and mark it (quietly: a look, not reading).
            if let found = pendingFound, found.section == spineIndex {
                pendingFound = nil
                web?.run("window.bookReader?.found.show(\(found.run), \(found.offset), \(found.length))")
            }
            // Read-along: the cue waiting for this section, or the current one shown again.
            if let pending = pendingReadAlong, pending.cue.section == spineIndex {
                pendingReadAlong = nil
                showReadAlong(pending.cue, follow: pending.follow)
            } else if let cue = readAlongCue, cue.section == spineIndex {
                showReadAlong(cue, follow: false)
            }
            if auditsPages { auditFont() }
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
        // With the popup open, a tap that misses a word only closes it.
        if popup != nil {
            popup = nil
            return
        }
        let zone = x / max(viewSize.width, 1)
        // Facing pages: only the outer edges turn, so the middle of either page shows the controls.
        let edge = spread ? 0.12 : 0.25
        // Settings: the sides swapped, or taps that never turn pages.
        let leftGoesOn = readsRightToLeft != (settings.tapZones == .inverted)
        if settings.tapZones == .off {
            showsChrome.toggle()
        } else if zone < edge {
            leftGoesOn ? nextPage() : previousPage()
        } else if zone > 1 - edge {
            leftGoesOn ? previousPage() : nextPage()
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
            // And the sentence for a highlight, and the highlight it's in: the section can lay
            // out again while the popup opens, and the point would then be somewhere else.
            let sentence = marks == nil ? nil : await object(source, "window.bookReader.marks.sentenceAt(\(rect.midX), \(rect.midY))")
            let inMark = marks == nil ? nil : await source.evaluate("window.bookReader.marks.markAt(\(rect.midX), \(rect.midY))") as? String
            let page = await lookup.lookup(text: text, utf16Offset: offset)
            // Nothing there to look up: like a tap that missed a word, it closes an open popup.
            guard let length = page.results.first?.matched.utf16.count, length > 0 else { popup = nil; return }
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
            tappedSource = onCompanion
            tappedSentence = sentence
            tappedHighlight = marks?.highlights.first { $0.id.map(String.init) == inMark }
        }
    }

    // MARK: Highlights and bookmarks

    /// Which page the open popup's word is on (the facing page's, or this one's), and where.
    private var tappedSource = false
    /// The sentence the looked-up word is in, as Kavita keeps a highlight ({xpath, endXPath, text}).
    private var tappedSentence: [String: Any]?

    /// Draws the volume's highlights on the section each page shows.
    func showMarks() {
        func payload(_ section: Int?) -> String {
            let list: [[String: Any]] = (marks?.highlights ?? []).filter { $0.page == section }.compactMap { mark in
                guard let id = mark.id, let xpath = mark.xpath, let text = mark.text else { return nil }
                return ["id": id, "xpath": xpath, "endXPath": mark.endXPath ?? xpath, "text": text, "color": BookMarks.color(mark.slot)]
            }
            return BookWebController.json(list)
        }
        web?.run("window.bookReader?.marks.show(\(payload(spineIndex)))")
        if let companion, let section = companionSection { companion.run("window.bookReader?.marks.show(\(payload(section)))") }
        // The popup's highlight follows its row (a colour or note changed).
        if let tapped = tappedHighlight { tappedHighlight = marks?.highlights.first { $0.id == tapped.id } }
    }

    /// Highlights the sentence the looked-up word is in, or changes its highlight's colour.
    public func highlightTapped(slot: Int) {
        guard let marks else { return }
        if let tapped = tappedHighlight {
            marks.edit(tapped, note: tapped.note, slot: slot)
            return
        }
        let section = tappedSource ? (companionSection ?? spineIndex) : spineIndex
        guard let place = tappedSentence, let xpath = place["xpath"] as? String, let text = place["text"] as? String,
              !text.isEmpty else { return }
        tappedHighlight = marks.addHighlight(page: section, xpath: xpath, endXPath: place["endXPath"] as? String ?? xpath,
                                             text: text, slot: slot)
    }

    /// Writes a note on the looked-up word's highlight (highlighting its sentence first).
    public func noteOnTapped() {
        guard let marks else { return }
        if let tapped = tappedHighlight {
            editingNote = tapped
            return
        }
        let section = tappedSource ? (companionSection ?? spineIndex) : spineIndex
        guard let place = tappedSentence, let xpath = place["xpath"] as? String, let text = place["text"] as? String,
              !text.isEmpty else { return }
        tappedHighlight = marks.addHighlight(page: section, xpath: xpath, endXPath: place["endXPath"] as? String ?? xpath,
                                             text: text, slot: 0)
        editingNote = tappedHighlight
    }

    public func removeTappedHighlight() {
        guard let tapped = tappedHighlight else { return }
        marks?.remove(tapped)
        tappedHighlight = nil
    }

    /// An object from the page, passed as JSON (as `tapPlace` does).
    private func object(_ source: BookWebController?, _ script: String) async -> [String: Any]? {
        guard let json = await source?.evaluate("JSON.stringify(\(script) ?? null)") as? String else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
    }

    /// The bookmark at the place on screen.
    public var currentBookmark: ReaderMark? { marks?.bookmark(page: spineIndex, xpath: currentXPath) }

    /// Bookmarks the place on screen, or removes its bookmark.
    public func toggleBookmark() {
        guard let marks, let web else { return }
        let page = spineIndex, xpath = currentXPath
        if marks.bookmark(page: page, xpath: xpath) != nil {
            marks.toggleBookmark(page: page, xpath: xpath, text: "")
            return
        }
        Task {
            let start = await object(web, "window.bookReader.marks.pageStart()")
            let text = (start?["text"] as? String).map { String($0.prefix(24)) } ?? ""
            marks.toggleBookmark(page: page, xpath: xpath ?? (start?["xpath"] as? String), text: text)
        }
    }

    // MARK: Read-along

    /// Set by the app while a paired book is read along.
    @ObservationIgnored public var readAlong: (any BookReadAlongHost)?
    /// The spoken sentence shown on the page.
    public private(set) var readAlongCue: ReadAlongCue?
    /// A cue to show once its section has loaded.
    private var pendingReadAlong: (cue: ReadAlongCue, follow: Bool)?
    /// The followed sentence goes on to the next page: how much of it is on screen (0…1).
    private var readAlongSplit: (cue: ReadAlongCue, fraction: Double)?

    /// Highlights the spoken sentence; with `follow`, turns (or opens its section) to keep it in view.
    // MARK: Added fonts

    /// The reader's added fonts (Yomu sets it before the book opens).
    @ObservationIgnored public var fonts: BookFontLibrary?

    private var customFontURL: String? {
        guard settings.font == .custom, let id = settings.customFont, fonts?.file(id: id) != nil else { return nil }
        return BookSchemeHandler.fontURL(id: id)?.absoluteString
    }

    // MARK: Search in the book

    public enum SearchState: Equatable, Sendable {
        case idle
        /// Reading the book's text the way the reader shows it, the first time (then cached).
        case preparing(Double)
        case ready
        case failed(String)
    }

    public private(set) var searchState = SearchState.idle
    /// Kept while the reader is open, so the sheet opens on the last search.
    public var searchQuery = ""
    public private(set) var searchHits: [BookSearch.Hit] = []
    @ObservationIgnored private var searchRuns: [BookTextRun]?
    /// Where the reader was before a search jump (Back returns there); gone at the next turn.
    public private(set) var searchBack: (section: Int, xpath: String?)?
    @ObservationIgnored private var pendingFound: BookSearch.Hit?

    /// Prepares the text (only when the search is opened) and searches it.
    public func search() async {
        if searchRuns == nil {
            searchState = .preparing(0)
            do {
                searchRuns = try await BookTextCollector.runs(chapterId: chapter.chapterId, repository: repository) { [weak self] fraction in
                    self?.searchState = .preparing(fraction)
                }
            } catch {
                searchState = .failed(error.localizedDescription)
                return
            }
        }
        searchState = .ready
        searchHits = BookSearch.hits(searchQuery, in: searchRuns ?? [])
    }

    /// The chapter a section belongs to, as the contents name it.
    public func sectionTitle(_ section: Int) -> String {
        package?.toc.last { $0.spineIndex <= section }?.title ?? "Section \(section + 1)"
    }

    /// Goes to a result and marks it: a look, not reading, so nothing is recorded (the place
    /// moves on only when reading continues from there, with a page turn). Contents, by contrast,
    /// records at once: choosing a chapter is a move to read there.
    public func jump(to hit: BookSearch.Hit) {
        if searchBack == nil { searchBack = (spineIndex, currentXPath) }
        hasMoved = false
        pendingFound = hit
        open(section: hit.section, at: .start)
    }

    /// Back to where the reader was before the search jump; records nothing either.
    public func goBackFromSearch() {
        guard let back = searchBack else { return }
        searchBack = nil
        hasMoved = false
        pendingFound = nil
        open(section: back.section, at: back.xpath.map { .xpath($0) } ?? .start)
    }

    /// Reading on from a jumped-to place: Back goes, and the found mark with it.
    private func leaveSearchPlace() {
        guard searchBack != nil else { return }
        searchBack = nil
        if readAlongCue == nil { web?.run("window.bookReader?.found.clear()") }
    }

    // MARK: Auto-scroll

    /// Tells the page to scroll at the chosen reading speed, or to stop.
    public func applyAutoScroll() async {
        guard autoScroll.isMoving, settings.layout == .scroll, let web else {
            web?.run("window.bookReader?.autoScroll(0)")
            return
        }
        let metrics = await web.evaluate("window.bookReader?.textMetrics()") as? [String: Any]
        func value(_ key: String) -> Double { (metrics?[key] as? NSNumber)?.doubleValue ?? 0 }
        let speed = AutoScroll.bookPointsPerSecond(charactersPerMinute: settings.autoScrollCharactersPerMinute, fontSize: value("fontSize"),
                                                   lineAdvance: value("lineAdvance"), lineLength: value("lineLength"))
        // A section that fits on the screen stays for the time its characters take.
        let characters = textIndex.sections.indices.contains(spineIndex) ? textIndex.sections[spineIndex] : 0
        let text = AutoScroll.dwellSeconds(picture: false, characters: characters, charactersPerMinute: settings.autoScrollCharactersPerMinute)
        guard autoScroll.isMoving else { return }
        web.run("window.bookReader?.autoScroll(\(speed), {text: \(text), picture: \(AutoScroll.pictureDwell)})")
    }

    public func showReadAlong(_ cue: ReadAlongCue?, follow: Bool) {
        // Read-along moves the page itself: auto-scroll gives way.
        if cue != nil { autoScroll.close() }
        readAlongCue = cue
        readAlongSplit = nil
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
        guard follow else { return }
        Task { await self.loadReadAlongSplit(cue, "window.bookReader?.readAlong.split() ?? null") }
    }

    /// While following: once the audio reaches the part of a sentence on the next page (by its
    /// share of the characters), turns to it rather than waiting for the next sentence.
    public func readAlongPlayed(to time: Double) {
        guard let split = readAlongSplit, split.cue == readAlongCue,
              time >= split.cue.start + split.fraction * (split.cue.end - split.cue.start) else { return }
        readAlongSplit = nil
        hasMoved = true
        Task { await self.loadReadAlongSplit(split.cue, "window.bookReader?.readAlong.advance() ?? null") }
    }

    private func loadReadAlongSplit(_ cue: ReadAlongCue, _ script: String) async {
        let fraction = await web?.evaluate(script) as? Double
        guard readAlongCue == cue else { return }
        readAlongSplit = fraction.map { (cue, $0) }
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

    /// Back in the foreground: see `repaint` in BookReader.js.
    func repaint() {
        web?.run("window.bookReader?.repaint()")
        companion?.run("window.bookReader?.repaint()")
    }

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

    /// "~12 min" to the end of the chapter (the contents entry) being read, at the same speed;
    /// nil when the book has no chapters, or the chapter's end is the book's.
    public var chapterTimeLeft: String? {
        guard let speed = readingSpeed, let package,
              let left = textIndex.charactersLeftInChapter(read: charactersRead, section: spineIndex, chapterStarts: package.toc.map(\.spineIndex)),
              left < totalCharacters - charactersRead else { return nil }
        return ActivityLog.timeLeft(characters: left, speed: speed)?.replacingOccurrences(of: " left", with: " in chapter")
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
