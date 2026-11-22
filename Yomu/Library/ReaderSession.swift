import AppCommon
import KavitaKit
import Readers
import SwiftUI

/// A chapter being read, with what's needed to move on to the next one.
struct ReaderSession: Codable, Identifiable, Hashable {
    var chapter: ReaderChapter
    var series: KavitaSeries
    var contents: KavitaSeriesContents
    /// Opens at this page rather than the reading position (a bookmark picked in the series).
    var startPage: Int?

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
    let onClose: () -> Void

    var body: some View {
        let next = session.contents.nextReaderChapter(after: session.chapter, series: session.series)
        Group {
            if session.series.isEpub {
                ReaderModelHost(make: { environment.makeBookReader(session.chapter, next: next) }) { model in
                    if let readAlong = model.readAlong as? ReadAlongModel {
                        BookReaderView(model: model, onClose: closeReader, onOpenChapter: { chapter in session.chapter = chapter; session.startPage = nil }) {
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
                        BookReaderView(model: model, onClose: closeReader, onOpenChapter: { chapter in session.chapter = chapter; session.startPage = nil })
                    }
                }
            } else {
                ReaderModelHost(make: { environment.makeReader(session.chapter, next: next, startPage: session.startPage) }) { model in
                    MangaReaderView(model: model, onClose: closeReader, onOpenChapter: { chapter in session.chapter = chapter; session.startPage = nil })
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
            #if os(iOS)
            OrientationLock.release()
            #endif
            ScreenAwake.set(false, reason: "reading")
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
        .task(id: session.chapter.chapterId) {
            // Moving on to the next volume can make automatic downloads fetch one more.
            environment.autoDownloads.openChapterId = session.chapter.chapterId
            environment.autoDownloads.schedule(after: 10)
        }
        .focusedSceneValue(\.readerClose, closeReader)
        #if os(macOS)
        .navigationTitle("\(session.chapter.seriesTitle) – \(session.chapter.title)")
        #endif
    }

    /// Awake for 15 minutes after the last page turn (or the reader opening).
    static func staysAwake(lastMoved: Date, now: Date) -> Bool {
        now.timeIntervalSince(lastMoved) < 15 * 60
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
