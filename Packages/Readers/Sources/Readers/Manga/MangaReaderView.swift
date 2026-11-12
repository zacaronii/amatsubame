import Core
import Lookup
import SwiftUI

/// Full-screen manga reader: paged (with spreads and zoom) or long strip.
public struct MangaReaderView: View {
    @Bindable var model: MangaReaderModel
    let onClose: () -> Void
    let onOpenChapter: (ReaderChapter) -> Void
    @Environment(\.scenePhase) private var scenePhase
    @State private var showsSettings = false
    @State private var readerFrame: CGRect = .zero
    /// The screen's side safe areas: on the iPhone Duo's outer screen, the status column.
    @State private var sideInsets = SideInsets()
    /// Debug: show how long the last tap-to-popup took (Settings → OCR).
    @AppStorage("showLookupTimings") private var showsTimings = false

    public init(model: MangaReaderModel, onClose: @escaping () -> Void, onOpenChapter: @escaping (ReaderChapter) -> Void) {
        self.model = model
        self.onClose = onClose
        self.onOpenChapter = onOpenChapter
    }

    public var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.ignoresSafeArea()
                switch model.state {
                case .loading:
                    ProgressView().tint(.white)
                case .failed(let message):
                    ContentUnavailableView {
                        Label("Couldn't Open Chapter", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("Retry") { Task { await model.load() } }
                        Button("Close", action: close)
                    }
                    .foregroundStyle(.white)
                case .ready:
                    content
                }
                if model.isSelecting {
                    ManualSelectionOverlay(model: model)
                }
                if let toast = model.toast {
                    Text(toast)
                        .font(.callout)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.regularMaterial, in: .capsule)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, 80)
                        .allowsHitTesting(false)
                        .accessibilityIdentifier("reader.toast")
                }
                if model.showsChrome || model.state != .ready {
                    ReaderChrome(model: model, onClose: close, onSettings: { showsSettings = true })
                        .transition(.opacity)
                }
            }
            .overlay(alignment: .bottomLeading) { statusBadges }
            .overlay {
                // The chapter's progress along the screen's bottom edge, as in the book reader.
                if model.state == .ready, model.pageCount > 0 {
                    ReaderProgressBar(fraction: Double(model.currentPage + 1) / Double(model.pageCount),
                                      rightToLeft: model.settings.direction == .rightToLeft, track: .gray)
                        .ignoresSafeArea()
                }
            }
            .onAppear {
                updateSpreadFit(geometry.size)
                readerFrame = geometry.frame(in: .global)
                sideInsets = SideInsets(geometry.safeAreaInsets)
            }
            .onChange(of: geometry.size) { _, size in
                updateSpreadFit(size)
                readerFrame = geometry.frame(in: .global)
            }
            .onChange(of: SideInsets(geometry.safeAreaInsets)) { _, insets in sideInsets = insets }
        }
        .popover(item: $model.popup, attachmentAnchor: .rect(.rect(popupAnchor)),
                 arrowEdge: PopupPlacement.arrowEdge(for: popupAnchor, width: readerFrame.width)) { popup in
            if let lookup = model.lookup {
                LookupPopupView(service: lookup, model: popup)
                    // Narrow enough for the space beside the word: iOS cuts a popover down to fit, and
                    // on the open iPhone Duo held upright a 360 pt minimum clipped both sides.
                    .frame(minWidth: 280, idealWidth: 420, minHeight: 360, idealHeight: 520)
                    .presentationCompactAdaptation(.sheet)
                    .presentationDetents([.medium, .large])
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.showsChrome)
        .focusedSceneValue(\.readerPaging, ReaderPaging(next: { model.requestPage(1) }, previous: { model.requestPage(-1) }))
        .task { await model.load() }
        .onDisappear { model.flushProgress() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { model.flushProgress() }
        }
        .sheet(isPresented: $showsSettings) {
            ReaderSettingsSheet(model: model)
        }
        #if os(iOS)
        // Hidden with the controls too: on the open iPhone Duo the clock and Wi-Fi drew over the
        // first column and the Aa button.
        .statusBarHidden(true)
        .persistentSystemOverlays(model.showsChrome ? .automatic : .hidden)
        #endif
    }

    @ViewBuilder private var content: some View {
        switch model.settings.mode {
        case .paged:
            PagedReaderView(model: model, sideInsets: sideInsets, onOpenChapter: openNext)
        case .longStrip:
            LongStripReaderView(model: model, onOpenChapter: openNext)
        }
    }

    /// The tapped block in this view's coordinates (taps report global coordinates).
    private var popupAnchor: CGRect {
        model.popupAnchor.offsetBy(dx: -readerFrame.minX, dy: -readerFrame.minY)
    }

    @ViewBuilder private var statusBadges: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let message = model.ocrMessage, model.showsChrome {
                Label(message, systemImage: "text.viewfinder")
            }
            if showsTimings, let timings = model.lastTimings {
                Text(timingText(timings)).monospacedDigit().accessibilityIdentifier("reader.timings")
            }
        }
        .font(.caption)
        .padding(8)
        .background(.regularMaterial, in: .rect(cornerRadius: 8))
        .padding(12)
        .opacity(model.ocrMessage == nil && !(showsTimings && model.lastTimings != nil) ? 0 : 1)
        .allowsHitTesting(false)
    }

    private func timingText(_ timings: LookupTimings) -> String {
        func ms(_ duration: Duration) -> String { "\(Int(duration / .milliseconds(1))) ms" }
        let ocr = timings.ocr.map { "OCR \(ms($0)) · " } ?? "text ready · "
        return ocr + "lookup \(ms(timings.lookup)) · total \(ms(timings.total))"
    }

    private func updateSpreadFit(_ size: CGSize) {
        model.spreadsFitScreen = size.width > size.height && size.width >= 700
    }

    private func openNext(_ chapter: ReaderChapter) {
        model.flushProgress()
        onOpenChapter(chapter)
    }

    private func close() {
        model.flushProgress()
        onClose()
    }
}
