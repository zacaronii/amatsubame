import Core
import Lookup
import SwiftUI

/// Full-screen EPUB reader: paged or scrolling, vertical or horizontal text.
public struct BookReaderView: View {
    @Bindable var model: BookReaderModel
    let onClose: () -> Void
    let onOpenChapter: (ReaderChapter) -> Void
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @State private var showsSettings = false
    @State private var showsContents = false
    @State private var pageWidth: CGFloat = 0
    /// The hinge of a foldable iPhone (the Duo): closed is when the folded page is measured.
    @State private var hinge = Fold.Hinge.unknown
    /// The folded screen's page ("382x644"), measured the last time a book was read folded:
    /// facing pages open take that size, so they break at the same places. Until then they
    /// use the Duo's known size (`SpreadFrames.knownFoldedPage`).
    @AppStorage("bookFoldedPage") private var foldedPage = ""
    /// This iPhone has reported a hinge (the outer screen may not report one while folded).
    @AppStorage("deviceFolds") private var deviceFolds = false
    /// The app's read-along bar (Yomu), shown above the bottom edge.
    private let accessory: AnyView?
    /// The app's button in the top bar, before Reader Settings (Yomu's read-along switch).
    private let barItem: AnyView?
    /// Above the lookup popup (Yomu's read-along clip row).
    private let popupHeader: AnyView?

    public init(model: BookReaderModel, onClose: @escaping () -> Void, onOpenChapter: @escaping (ReaderChapter) -> Void) {
        self.model = model
        self.onClose = onClose
        self.onOpenChapter = onOpenChapter
        accessory = nil
        barItem = nil
        popupHeader = nil
    }

    public init<Accessory: View, BarItem: View, PopupHeader: View>(
        model: BookReaderModel, onClose: @escaping () -> Void, onOpenChapter: @escaping (ReaderChapter) -> Void,
        @ViewBuilder accessory: () -> Accessory, @ViewBuilder barItem: () -> BarItem, @ViewBuilder popupHeader: () -> PopupHeader
    ) {
        self.model = model
        self.onClose = onClose
        self.onOpenChapter = onOpenChapter
        self.accessory = AnyView(accessory())
        self.barItem = AnyView(barItem())
        self.popupHeader = AnyView(popupHeader())
    }

    public var body: some View {
        GeometryReader { geometry in
            let frames = spreadFrames(geometry)
            ZStack {
                pageColor.ignoresSafeArea()
                switch model.state {
                case .loading:
                    ProgressView("Opening book…")
                case .failed(let message):
                    ContentUnavailableView {
                        Label("Couldn't Open Book", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("Retry") { Task { await model.load() } }
                        Button("Close", action: close)
                    }
                case .ready:
                    if let web = model.web, let frames, let companion = model.companion {
                        facingPages(web: web, companion: companion, frames: frames)
                    } else if let web = model.web {
                        BookWebView(controller: web)
                            .ignoresSafeArea()
                            .accessibilityIdentifier("book.page")
                            .accessibilityValue(positionDescription)
                            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { pageWidth = $0 }
                            .popover(item: Binding(get: { model.spread ? nil : model.popup }, set: { model.popup = $0 }), attachmentAnchor: .rect(.rect(model.popupAnchor)),
                                     arrowEdge: PopupPlacement.arrowEdge(for: model.popupAnchor, width: pageWidth)) { popup in
                                if let lookup = model.lookup {
                                    VStack(spacing: 0) {
                                        if let popupHeader { popupHeader }
                                        LookupPopupView(service: lookup, model: popup)
                                    }
                                    // Narrow enough for the space beside the word: iOS cuts a popover down to fit, and
                                    // on the open iPhone Duo held upright a 360 pt minimum clipped both sides.
                                    .frame(minWidth: 280, idealWidth: 420, minHeight: 360, idealHeight: 520)
                                    .presentationCompactAdaptation(.sheet)
                                    .presentationDetents([.medium, .large])
                                }
                            }
                    }
                }
                if model.auditsPages {
                    // UI tests read the page audit from here.
                    Text(model.auditResults.joined(separator: "\n"))
                        .font(.system(size: 1))
                        .opacity(0.01)
                        .allowsHitTesting(false)
                        .accessibilityIdentifier("book.audit")
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
                if model.state == .ready, let accessory {
                    // In the stack with the page (not an overlay), so its buttons get the taps.
                    accessory
                        .padding(.horizontal, 16)
                        // Above the progress line the controls show.
                        .padding(.bottom, model.showsChrome ? 76 : 22)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .inFirstPage(model.spread ? frames : nil)
                }
                if model.spread, let frames, let popup = model.popup {
                    lookupPanel(popup, over: model.popupOnCompanion ? frames.first : frames.second)
                }
                if model.showsChrome || model.state != .ready {
                    // Facing pages: the controls stay inside the first page.
                    chrome.inFirstPage(model.spread ? frames : nil).transition(.opacity)
                }
            }
            .overlay {
                if model.state == .ready {
                    bottomProgress(in: geometry, spread: model.spread ? frames : nil)
                }
            }
            .onAppear {
                model.viewSize = geometry.size
                model.setSafeArea(insets(geometry.safeAreaInsets), size: geometry.size)
            }
            .onChange(of: frames, initial: true) { _, frames in
                model.spreadFrames = frames.map { ($0.first, $0.second) }
                model.spread = frames != nil
            }
            .onChange(of: foldedMeasurement(geometry), initial: true) { _, size in
                guard let size else { return }
                // The status bar only ever takes height away (in passing, while folding): the
                // tallest page seen at this width is the folded screen's.
                let kept = Self.size(foldedPage)
                let height = kept?.width == size.width ? max(kept?.height ?? 0, size.height) : size.height
                foldedPage = "\(Int(size.width))x\(Int(height))"
            }
            .focusedSceneValue(\.readerPaging, ReaderPaging(next: { model.nextPage() }, previous: { model.previousPage() }))
            .onChange(of: geometry.size) { _, size in
                model.viewSize = size
                model.setSafeArea(insets(geometry.safeAreaInsets), size: geometry.size)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.showsChrome)
        .onHingeChange { hinge in
            self.hinge = hinge
            if hinge != .unknown { deviceFolds = true }
        }
        .task {
            model.prefersDark = colorScheme == .dark
            await model.load()
        }
        .onChange(of: colorScheme) { _, scheme in model.prefersDark = scheme == .dark }
        // A word mined, Anki refreshed, or marks switched off: restyle the words on the page.
        .onChange(of: model.lookup?.mining?.revision) { Task { await model.markWords() } }
        .onDisappear { model.flushProgress() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { model.flushProgress() }
        }
        .sheet(isPresented: $showsSettings) { BookSettingsSheet(model: model) }
        .sheet(isPresented: $showsContents) { contents }
        #if os(iOS)
        // Hidden with the controls too: on the open iPhone Duo the clock and Wi-Fi drew over the
        // first column and the Aa button.
        .statusBarHidden(true)
        .persistentSystemOverlays(model.showsChrome ? .automatic : .hidden)
        #endif
    }

    private var pageColor: Color {
        switch model.settings.theme {
        case .system: colorScheme == .dark ? .black : .white
        case .light: .white
        case .sepia: Color(red: 0.957, green: 0.925, blue: 0.847)
        case .dark: .black
        }
    }

    /// Hoshi-style progress: percentage, characters read of the whole book, and time left at
    /// this reader's speed ("0.5% · 433 / 93,540 字 · ~6 h left").
    private var progressLine: some View {
        // Rounded down, like the series page.
        let percent = model.progressFraction.formatted(.percent.precision(.fractionLength(model.progressFraction < 0.1 ? 1 : 0)).rounded(rule: .down))
        let parts = [percent, "\(model.charactersRead.formatted()) / \(model.totalCharacters.formatted()) 字", model.timeLeft]
        return Text(parts.compactMap(\.self).joined(separator: " · "))
            .font(.caption2)
            .monospacedDigit()
            .foregroundStyle(model.showsChrome ? AnyShapeStyle(.secondary) : AnyShapeStyle(ink.opacity(0.55)))
            .accessibilityIdentifier("book.progress")
    }

    private func insets(_ insets: EdgeInsets) -> EdgeInsetsValue {
        EdgeInsetsValue(top: insets.top, leading: insets.leading, bottom: insets.bottom, trailing: insets.trailing)
    }

    /// Text color of the page's theme (the reader's theme can differ from the system's).
    private var ink: Color {
        switch model.settings.theme {
        case .dark: .white
        case .system: colorScheme == .dark ? .white : .black
        case .light: .black
        case .sepia: Color(red: 0.29, green: 0.23, blue: 0.16)
        }
    }

    private var positionDescription: String {
        "Section \(model.spineIndex + 1) of \(model.sectionCount), page \(model.sectionPage + 1) of \(model.sectionPages)"
    }

    // MARK: Facing pages

    /// Two pages either side of the crease when the screen is open (or half open like a book) in
    /// landscape; nil otherwise, or while scrolling.
    private func spreadFrames(_ geometry: GeometryProxy) -> SpreadFrames? {
        guard model.state == .ready, model.settings.layout == .paged, let fold = Fold.crossing(geometry) else { return nil }
        let insets = geometry.safeAreaInsets
        let screen = CGSize(width: geometry.size.width + insets.leading + insets.trailing, height: geometry.size.height + insets.top + insets.bottom)
        return SpreadFrames.make(size: geometry.size, insets: (insets.top, insets.leading, insets.bottom, insets.trailing), fold: fold.frame,
                                 folded: Self.size(foldedPage) ?? SpreadFrames.knownFoldedPage(openScreen: screen),
                                 rightToLeft: model.readsRightToLeft)
    }

    /// The page as the folded screen shows it (its size less the insets the text keeps clear of),
    /// while folded and upright.
    private func foldedMeasurement(_ geometry: GeometryProxy) -> CGSize? {
        guard hinge == .closed || deviceFolds && Fold.crossing(geometry) == nil, model.state == .ready, !model.spread else { return nil }
        let insets = geometry.safeAreaInsets, kept = model.safeAreaInsets
        let screen = CGSize(width: geometry.size.width + insets.leading + insets.trailing,
                            height: geometry.size.height + insets.top + insets.bottom)
        guard screen.height > screen.width else { return nil }
        return CGSize(width: screen.width - kept.leading - kept.trailing, height: screen.height - kept.top - kept.bottom)
    }

    private static func size(_ text: String) -> CGSize? {
        let parts = text.split(separator: "x").compactMap { Double($0) }
        return parts.count == 2 ? CGSize(width: parts[0], height: parts[1]) : nil
    }

    private func facingPages(web: BookWebController, companion: BookWebController, frames: SpreadFrames) -> some View {
        ZStack {
            // Around the pages (their margins, the crease) taps work as on the pages.
            Color.clear
                .contentShape(.rect)
                .onTapGesture { location in model.tapZone(x: location.x) }
            BookWebView(controller: web)
                .frame(width: frames.first.width, height: frames.first.height)
                .accessibilityIdentifier("book.page")
                .accessibilityValue(positionDescription)
                .position(x: frames.first.midX, y: frames.first.midY)
            BookWebView(controller: companion)
                .frame(width: frames.second.width, height: frames.second.height)
                .accessibilityIdentifier("book.facingPage")
                .position(x: frames.second.midX, y: frames.second.midY)
        }
    }

    /// The progress bar along the screen's bottom edge (across both facing pages), and the
    /// always-on progress text just above it (under the first page when facing).
    private func bottomProgress(in geometry: GeometryProxy, spread frames: SpreadFrames?) -> some View {
        let bottom = geometry.size.height + geometry.safeAreaInsets.bottom
        return ZStack {
            if model.settings.showsProgressBar {
                ReaderProgressBar(fraction: model.progressFraction, rightToLeft: model.readsRightToLeft, track: ink)
                    .ignoresSafeArea()
            }
            if model.settings.progressText == .always, !model.showsChrome {
                progressLine
                    .position(x: frames?.first.midX ?? geometry.size.width / 2, y: bottom - Self.progressTextLift)
                    .allowsHitTesting(false)
            }
        }
    }

    /// The progress text's middle, above the screen's bottom edge (clear of the bar).
    static let progressTextLift: CGFloat = 17

    /// The lookup over the other page from the word, never across the crease.
    private func lookupPanel(_ popup: LookupPopupModel, over page: CGRect) -> some View {
        let height = min(page.height - 16, 560)
        return VStack(spacing: 0) {
            if let popupHeader { popupHeader }
            if let lookup = model.lookup { LookupPopupView(service: lookup, model: popup) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("book.lookupPanel")
        .background(.background)
        .clipShape(.rect(cornerRadius: 20))
        .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
        .overlay(alignment: .topTrailing) {
            Button { model.popup = nil } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(8)
            .accessibilityLabel("Close dictionary")
            .accessibilityIdentifier("book.closeLookup")
        }
        .frame(width: page.width - 16, height: height)
        .position(x: page.midX, y: page.minY + 8 + height / 2)
        .transition(.opacity)
    }

    // MARK: Controls

    private var chrome: some View {
        VStack {
            HStack(spacing: 8) {
                Button("Close", systemImage: "xmark", action: close)
                    .accessibilityIdentifier("reader.close")
                    .labelStyle(.iconOnly)
                    .keyboardShortcut(.cancelAction)
                    .buttonBorderShape(.circle)
                VStack(spacing: 2) {
                    Text(model.chapter.seriesTitle).font(.headline).lineLimit(1)
                    Text(model.currentSectionTitle ?? model.chapter.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                Button("Contents", systemImage: "list.bullet") { showsContents = true }
                    .labelStyle(.iconOnly)
                    .buttonBorderShape(.circle)
                    .disabled(model.package?.toc.isEmpty ?? true)
                if let barItem { barItem }
                ReaderSettingsButton { showsSettings = true }
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .padding(8)
            .glassEffect(in: .capsule)
            .padding(.horizontal)

            Spacer()

            if model.reachedEnd {
                if let next = model.nextChapter {
                    Button("Read \(next.title)", systemImage: "arrow.forward.circle.fill") {
                        model.flushProgress()
                        onOpenChapter(next)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("reader.next")
                } else {
                    Label("End of book", systemImage: "checkmark.circle").font(.callout)
                }
            }

            if model.state == .ready, model.settings.progressText != .hidden {
                progressLine
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .glassEffect(in: .capsule)
            }
        }
        .padding(.vertical, 8)
    }

    private var contents: some View {
        NavigationStack {
            List(model.package?.toc ?? []) { entry in
                Button {
                    showsContents = false
                    model.showsChrome = false
                    model.go(to: entry)
                } label: {
                    HStack {
                        Text(entry.title)
                            .padding(.leading, CGFloat(entry.depth) * 16)
                            .foregroundStyle(.primary)
                        Spacer()
                        if entry.spineIndex == model.spineIndex {
                            Image(systemName: "bookmark.fill").foregroundStyle(.tint)
                        }
                    }
                }
            }
            .navigationTitle("Contents")
            .toolbar {
                Button("Done") { showsContents = false }
            }
        }
        .frame(minWidth: 360, minHeight: 420)
    }

    private func close() {
        model.flushProgress()
        onClose()
    }
}

/// The reader's Aa button: round and tinted, opening its settings.
struct ReaderSettingsButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("Aa").font(.headline).frame(width: 26, height: 26)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .accessibilityLabel("Reader Settings")
        .accessibilityIdentifier("reader.settings")
    }
}

struct BookSettingsSheet: View {
    @Bindable var model: BookReaderModel
    @Environment(\.dismiss) private var dismiss

    private static let sepiaPage = Color(red: 0.957, green: 0.925, blue: 0.847)
    private static let sepiaInk = Color(red: 0.29, green: 0.23, blue: 0.16)

    var body: some View {
        NavigationStack {
            Form {
                Section("Theme") {
                    ThemeTiles(tiles: [
                        .init(theme: .system, title: "System", page: .white, ink: .black, split: true),
                        .init(theme: .light, title: "Light", page: .white, ink: .black),
                        .init(theme: .sepia, title: "Sepia", page: Self.sepiaPage, ink: Self.sepiaInk),
                        .init(theme: .dark, title: "Dark", page: .black, ink: .white),
                    ], selection: $model.settings.theme)
                    .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                    .accessibilityIdentifier("settings.theme")
                }
                Section("Text") {
                    Picker("Font", selection: $model.settings.font) {
                        Text("Book's").tag(BookReaderSettings.Font.book)
                        Text("明朝").tag(BookReaderSettings.Font.mincho)
                        Text("ゴシック").tag(BookReaderSettings.Font.gothic)
                    }
                    .pickerStyle(.segmented)
                    RoundStepperRow("Size", value: $model.settings.fontSize, in: 12...40, step: 1) { "\(Int($0)) pt" }
                    RoundStepperRow("Line spacing", value: $model.settings.lineHeight, in: 1.2...2.6, step: 0.1) {
                        $0.formatted(.number.precision(.fractionLength(1)))
                    }
                    RoundStepperRow("Side margins", value: $model.settings.margin, in: 8...80, step: 4) { "\(Int($0)) pt" }
                }
                Section("Layout") {
                    Picker("Pages", selection: $model.settings.layout) {
                        Text("Paged").tag(BookReaderSettings.Layout.paged)
                        Text("Scrolling").tag(BookReaderSettings.Layout.scroll)
                    }
                    Picker("Text direction", selection: $model.settings.writingMode) {
                        Text("As in book").tag(BookReaderSettings.WritingMode.auto)
                        Text("Vertical").tag(BookReaderSettings.WritingMode.vertical)
                        Text("Horizontal").tag(BookReaderSettings.WritingMode.horizontal)
                    }
                }
                Section {
                    if let mining = model.lookup?.mining {
                        Toggle("Mark words by Anki state", isOn: Binding {
                            _ = mining.revision
                            return mining.marksWords
                        } set: {
                            mining.setMarksWords($0)
                        })
                        .accessibilityIdentifier("settings.marksWords")
                    }
                    Picker("Furigana", selection: $model.settings.furigana) {
                        Text("From book").tag(BookReaderSettings.Furigana.book)
                        Text("Hidden").tag(BookReaderSettings.Furigana.hidden)
                    }
                    .accessibilityIdentifier("settings.furigana")
                } header: {
                    Text("Lookup")
                } footer: {
                    Text("Underlines words you haven\u{2019}t mined, and words you\u{2019}re still learning. Known words stay plain.")
                }
                Section {
                    Picker("Progress text", selection: $model.settings.progressText) {
                        Text("Always").tag(BookReaderSettings.ProgressText.always)
                        Text("With controls").tag(BookReaderSettings.ProgressText.withControls)
                        Text("Hidden").tag(BookReaderSettings.ProgressText.hidden)
                    }
                    Toggle("Progress bar", isOn: $model.settings.showsProgressBar)
                } header: {
                    Text("Progress")
                } footer: {
                    Text("Progress text is the percentage and characters read of the whole book, and the time left at your reading speed, along the bottom. With controls shows it when you tap the middle of the page. The bar is a thin line under it.")
                }
                Section {
                    Button("Use for All Books") { model.saveSettingsAsDefault() }
                } footer: {
                    Text("These settings are kept for this series. Use for All Books makes them the default for the others.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Reader Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .frame(minWidth: 380, minHeight: 460)
    }
}

private extension View {
    /// Facing pages: confines the reader's controls to the first page (and its number row).
    @ViewBuilder func inFirstPage(_ frames: SpreadFrames?) -> some View {
        if let frames {
            frame(width: frames.first.width, height: frames.first.height + SpreadFrames.bottomRoom)
                .position(x: frames.first.midX, y: frames.first.midY + SpreadFrames.bottomRoom / 2)
        } else {
            self
        }
    }
}
