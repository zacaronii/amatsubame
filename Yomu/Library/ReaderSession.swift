import AppCommon
import KavitaKit
import Names
import Readers
import SwiftUI

/// A chapter being read, with what's needed to move on to the next one.
struct ReaderSession: Codable, Identifiable, Hashable {
    var chapter: ReaderChapter
    var series: KavitaSeries
    var contents: KavitaSeriesContents
    /// Opens at this page rather than the reading position (a bookmark picked in the series).
    var startPage: Int?
    /// And in a book, the place on that page (Kavita's XPath).
    var startXPath: String?
    /// Opened from this reading list (its local id): the end of a volume offers the list's next.
    /// For as long as this reader is open; any other way in reads the series as usual.
    var readingListId: Int64?

    var id: Int { chapter.chapterId }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.chapter == rhs.chapter }
    func hash(into hasher: inout Hasher) { hasher.combine(chapter) }
}

extension FocusedValues {
    /// Closes the reader in front (menu: Back to Library).
    @Entry var readerClose: (() -> Void)?
}

extension Notification.Name {
    /// Posted when a reader closes so series screens can refresh progress.
    static let readerDidClose = Notification.Name("readerDidClose")
}

/// Hosts the manga or book reader and swaps chapters in place when "Read next" is tapped.
struct ReaderContainer: View {
    @Environment(AppEnvironment.self) private var environment
    @State var session: ReaderSession
    /// Bumped when a link reopens the same volume, so its reader (and read-along) start again.
    @State private var opened = 0
    /// What the end of the volume offers while reading in a list (nil: the series' next).
    @State private var offer: NextOffer?
    /// What opening the series did for the character names (shown to UI tests in Debug).
    @State private var namesOutcome: CharacterNamesOutcome?
    let onClose: () -> Void

    var body: some View {
        let next = session.contents.nextReaderChapter(after: session.chapter, series: session.series)
        Group {
            if session.series.isEpub {
                ReaderModelHost(make: { environment.makeBookReader(session.chapter, next: next,
                                                                   start: session.startPage.map { ($0, session.startXPath) }) }) { model in
                    Group {
                        if let readAlong = model.readAlong as? ReadAlongModel {
                            BookReaderView(model: model, onClose: closeReader, onOpenChapter: open) {
                                if readAlong.isOn {
                                    ReadAlongBar(model: readAlong, showsControls: model.showsChrome)
                                        .task {
                                            // After the first page has laid out, so listening can start from it.
                                            try? await Task.sleep(for: .milliseconds(600))
                                            await readAlong.start()
                                        }
                                        .onDisappear { readAlong.close() }
                                }
                            } barItem: {
                                ReadAlongSwitch(model: readAlong)
                            } popupHeader: {
                                ReadAlongClipRow(model: readAlong)
                            }
                        } else {
                            BookReaderView(model: model, onClose: closeReader, onOpenChapter: open)
                        }
                    }
                    .onChange(of: offer, initial: true) { model.nextOffer = offer }
                    .onChange(of: model.autoScroll.isOn) { _, on in ScreenAwake.set(on, reason: "autoScroll") }
                }
            } else {
                ReaderModelHost(make: { environment.makeReader(session.chapter, next: next, startPage: session.startPage) }) { model in
                    MangaReaderView(model: model, onClose: closeReader, onOpenChapter: open)
                        .onChange(of: offer, initial: true) { model.nextOffer = offer }
                        // Auto-scroll keeps the screen on while it runs (it stops after 30 minutes untouched).
                        .onChange(of: model.autoScroll.isOn) { _, on in ScreenAwake.set(on, reason: "autoScroll") }
                }
            }
        }
        .id("\(session.chapter.chapterId)-\(opened)")
        .onAppear {
            environment.readerIsOpen = true
            #if os(iOS)
            OrientationLock.readerOpened()
            #endif
        }
        .onDisappear {
            environment.readerIsOpen = false
            // Its cast leaves the character names dictionary.
            let names = environment.common.characterNames
            Task { await names.close(app: "yomu") }
            #if os(iOS)
            OrientationLock.release()
            #endif
            ScreenAwake.set(false, reason: "reading")
            ScreenAwake.set(false, reason: "autoScroll")
        }
        .task {
            // The screen stays on while you read (a page of Japanese can take minutes), and may
            // sleep again once nothing has moved for a while: a book left open isn't being read.
            let opened = Date()
            ScreenAwake.set(true, reason: "reading")
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                let moved = (try? environment.readingProgress.progress(chapterId: session.chapter.chapterId))??.updatedAt ?? opened
                ScreenAwake.set(ReaderContainer.staysAwake(lastMoved: max(moved, opened), now: Date()), reason: "reading")
            }
        }
        .onChange(of: environment.requestedReader) { _, requested in
            // A link while reading (Read in Yomu): the reader in front switches to it.
            guard let requested else { return }
            environment.requestedReader = nil
            if requested.chapter.chapterId == session.chapter.chapterId { opened += 1 } else { session = requested }
        }
        .task(id: ListKey(chapterId: session.chapter.chapterId, listId: session.readingListId)) {
            // Reading in a list: the offer follows the list as it changes (a refresh, a move).
            guard let listId = session.readingListId else {
                offer = nil
                return
            }
            // At once, so a swapped-in volume never shows the previous one's offer.
            offer = makeOffer(listId: listId)
            do {
                for try await _ in environment.readingLists.observeItems(listId: listId) { offer = makeOffer(listId: listId).carrying(from: offer) }
            } catch {}
        }
        .onChange(of: environment.isLibraryOffline) {
            if let listId = session.readingListId { offer = makeOffer(listId: listId).carrying(from: offer) }
        }
        .task(id: session.series.id) {
            // The series' characters go into the names dictionary while it's open.
            namesOutcome = await environment.common.characterNames.open(environment.namedSeries(session.series), app: "yomu")
        }
        .task(id: session.chapter.chapterId) {
            // Moving on to the next volume can make automatic downloads fetch one more.
            environment.autoDownloads.openChapterId = session.chapter.chapterId
            environment.autoDownloads.schedule(after: 10)
        }
        .focusedSceneValue(\.readerClose, closeReader)
        #if DEBUG
        .overlay(alignment: .topLeading) {
            Color.clear.frame(width: 1, height: 1)
                .accessibilityElement()
                .accessibilityLabel("Character names: \(namesOutcome.map { "\($0)" } ?? "opening")")
                .accessibilityIdentifier("reader.characterNames")
        }
        #endif
        #if os(macOS)
        .navigationTitle("\(session.chapter.seriesTitle) – \(session.chapter.title)")
        #endif
    }

    /// Awake for 15 minutes after the last page turn (or the reader opening).
    static func staysAwake(lastMoved: Date, now: Date) -> Bool {
        now.timeIntervalSince(lastMoved) < 15 * 60
    }

    private struct ListKey: Hashable {
        var chapterId: Int
        var listId: Int64?
    }

    /// The list's next after the item read, the series' next beside it.
    private func makeOffer(listId: Int64) -> NextOffer {
        let seriesNext = session.contents.nextReaderChapter(after: session.chapter, series: session.series)
        let title = (try? environment.readingLists.list(listId))??.title ?? ""
        let skip = environment.readingListSkipper()
        let found = (try? environment.readingLists.next(after: session.chapter.chapterId, listId: listId, skip: skip)) ?? .notInList
        switch found {
        case .item(let item, let skipped):
            let chapter = ReaderChapter(chapterId: item.chapterId, volumeId: item.volumeId, seriesId: item.seriesId, libraryId: item.libraryId,
                                        pages: 0, title: item.title, seriesTitle: item.seriesName)
            let offline = environment.isLibraryOffline && environment.downloader.records[item.chapterId]?.state != .done
            let detail = [ReadingListSkip.summary(skipped), offline ? "not on this device" : nil].compactMap(\.self).joined(separator: " · ")
            let label = item.seriesName.isEmpty || item.seriesId == session.series.id ? item.title : "\(item.seriesName) · \(item.title)"
            return NextOffer.reading(in: title, .next(chapter, label: label, detail: detail.isEmpty ? nil : detail), seriesNext: seriesNext)
        case .end(let skipped):
            return NextOffer.reading(in: title, .end(detail: ReadingListSkip.summary(skipped)), seriesNext: seriesNext)
        case .notInList:
            return NextOffer.reading(in: title, .notInList, seriesNext: seriesNext)
        }
    }

    /// Opens a chapter offered at the end: in this series, in place (as always); in another
    /// series or format (a list's next), that series' reader replaces this one once it's on the
    /// device, the list kept. If it can't be opened, the offer says why and the reader stays.
    private func open(_ chapter: ReaderChapter) {
        // One at a time: while a choice is being fetched, the other does nothing.
        guard offer?.isOpening != true else { return }
        if chapter.seriesId == session.series.id,
           let found = session.contents.volumes.lazy.flatMap(\.chapters).first(where: { $0.id == chapter.chapterId }) {
            session.chapter = session.contents.readerChapter(found, series: session.series)
            session.startPage = nil
            session.startXPath = nil
            return
        }
        setOpening(chapter.chapterId, true, problem: nil)
        let from = Self.Reading(chapterId: session.chapter.chapterId, listId: session.readingListId)
        Task {
            do {
                var next = try await environment.session(chapterId: chapter.chapterId, seriesId: chapter.seriesId)
                // Dropped if something else opened meanwhile (a link): never swap what's being read.
                guard from.isStill(session) else { return }
                next.readingListId = session.readingListId
                session = next
            } catch {
                guard from.isStill(session) else { return }
                setOpening(chapter.chapterId, false, problem: error.localizedDescription)
            }
        }
    }

    /// What was being read when a fetch for the next started.
    struct Reading: Equatable {
        var chapterId: Int
        var listId: Int64?

        /// Its result is used only if the same chapter, in the same list, is still open.
        func isStill(_ session: ReaderSession) -> Bool {
            session.chapter.chapterId == chapterId && session.readingListId == listId
        }
    }

    private func setOpening(_ chapterId: Int, _ opening: Bool, problem: String?) {
        guard var current = offer else { return }
        for path in [\NextOffer.primary, \NextOffer.secondary] where current[keyPath: path]?.chapter.chapterId == chapterId {
            current[keyPath: path]?.isOpening = opening
            current[keyPath: path]?.problem = problem
        }
        offer = current
    }

    private func closeReader() {
        environment.autoDownloads.openChapterId = nil
        environment.autoDownloads.schedule()
        NotificationCenter.default.post(name: .readerDidClose, object: nil)
        onClose()
    }
}

/// Makes the reader's model once and keeps it. Built in `body`, a redraw of the screen
/// underneath (a download's progress, say) replaced it with a new one that never loaded:
/// a black screen with a spinner.
private struct ReaderModelHost<Model: AnyObject, Content: View>: View {
    let make: () -> Model
    @ViewBuilder let content: (Model) -> Content
    @State private var model: Model?

    var body: some View {
        if let model {
            content(model)
        } else {
            Color.black.ignoresSafeArea().onAppear { model = make() }
        }
    }
}

extension View {
    /// Full screen on iPhone/iPad; in the main window on Mac (replacing the tabs).
    func readerPresentation(_ session: Binding<ReaderSession?>) -> some View {
        #if os(iOS)
        fullScreenCover(item: session) { value in
            ReaderContainer(session: value) { session.wrappedValue = nil }
        }
        #else
        modifier(OpenReaderInMainWindow(session: session))
        #endif
    }
}

#if os(macOS)
private struct OpenReaderInMainWindow: ViewModifier {
    @Binding var session: ReaderSession?
    @Environment(AppEnvironment.self) private var environment

    func body(content: Content) -> some View {
        content.onChange(of: session) { _, value in
            guard let value else { return }
            environment.readingSession = value
            session = nil
        }
    }
}
#endif
