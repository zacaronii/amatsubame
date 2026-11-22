import Core
import SwiftUI

struct ReaderChrome: View {
    @Bindable var model: MangaReaderModel
    let onClose: () -> Void
    let onSettings: () -> Void
    @State private var scrubPage: Double?
    @State private var explainsBookmarks = false

    var body: some View {
        VStack {
            HStack(spacing: 8) {
                Button("Close", systemImage: "xmark", action: onClose)
                    .accessibilityIdentifier("reader.close")
                    .labelStyle(.iconOnly)
                    .keyboardShortcut(.cancelAction)
                    .buttonBorderShape(.circle)
                VStack(spacing: 2) {
                    Text(model.chapter.seriesTitle).font(.headline).lineLimit(1)
                    Text(model.chapter.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                if let bookmarks = model.bookmarks, model.state == .ready {
                    let page = model.currentPage
                    let marked = bookmarks.isBookmarked(page)
                    Button(marked ? "Remove Bookmark" : "Bookmark Page", systemImage: marked ? "bookmark.fill" : "bookmark") {
                        if marked || bookmarks.canBookmark { bookmarks.toggle(page) } else { explainsBookmarks = true }
                    }
                    .labelStyle(.iconOnly)
                    .buttonBorderShape(.circle)
                    .foregroundStyle(marked || bookmarks.canBookmark ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .accessibilityIdentifier("reader.bookmark")
                    .accessibilityValue(marked ? "Bookmarked" : "")
                    .alert("Page Bookmarks Are Off for This Account", isPresented: $explainsBookmarks) {
                        Button("OK", role: .cancel) {}
                    } message: {
                        Text("Kavita keeps bookmarks only for accounts with its Bookmark role. An admin can turn it on in Kavita\u{2019}s user settings.")
                    }
                }
                ReaderSettingsButton(action: onSettings)
                    .disabled(model.state != .ready)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .padding(8)
            .glassEffect(in: .capsule)
            .padding(.horizontal)

            Spacer()

            if model.state == .ready, model.pageCount > 1 {
                HStack(spacing: 12) {
                    Text("\(Int(scrubPage ?? Double(model.currentPage)) + 1) / \(model.pageCount)")
                        .monospacedDigit()
                        .font(.callout)
                        .accessibilityIdentifier("reader.pageCounter")
                    Slider(
                        value: Binding(
                            get: { scrubPage ?? Double(model.currentPage) },
                            set: { scrubPage = $0 }
                        ),
                        in: 0...Double(model.pageCount - 1),
                        step: 1
                    ) { editing in
                        if !editing, let page = scrubPage {
                            model.jump(to: Int(page))
                            scrubPage = nil
                        }
                    }
                    .environment(\.layoutDirection, model.settings.direction == .rightToLeft ? .rightToLeft : .leftToRight)
                }
                .padding(12)
                .glassEffect(in: .rect(cornerRadius: 20))
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
        }
    }
}

struct ReaderSettingsSheet: View {
    @Bindable var model: MangaReaderModel
    @Environment(\.dismiss) private var dismiss
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    var body: some View {
        NavigationStack {
            Form {
                Section("Layout") {
                    Picker("Mode", selection: $model.settings.mode) {
                        Text("Paged").tag(MangaReaderSettings.Mode.paged)
                        Text("Long strip").tag(MangaReaderSettings.Mode.longStrip)
                    }
                    .pickerStyle(.segmented)
                    Picker("Direction", selection: $model.settings.direction) {
                        Text("Right to left").tag(MangaReaderSettings.Direction.rightToLeft)
                        Text("Left to right").tag(MangaReaderSettings.Direction.leftToRight)
                    }
                    .disabled(model.settings.mode == .longStrip)
                    if model.settings.mode == .paged {
                        TapZonesPicker(selection: $model.settings.tapZones)
                        Toggle("Double-Tap to Zoom", isOn: $model.settings.doubleTapZooms)
                    }
                    RotationLockToggle()
                }
                if model.settings.mode == .paged {
                    Section("Two-Page Spreads") {
                        Picker("Spreads", selection: $model.settings.spreads) {
                            Text("Automatic").tag(MangaReaderSettings.Spreads.auto)
                            Text("On").tag(MangaReaderSettings.Spreads.on)
                            Text("Off").tag(MangaReaderSettings.Spreads.off)
                        }
                        Toggle("Show Cover Alone", isOn: $model.settings.coverAlone)
                    }
                } else {
                    Section("Page Width") {
                        RoundStepperRow("Page width", value: $model.settings.stripWidth, in: 0.6...1, step: 0.05) {
                            $0.formatted(.percent.precision(.fractionLength(0)))
                        }
                    }
                }
                Section {
                    Toggle("Show text boxes", isOn: $model.settings.showsTextBoxes)
                    Toggle("Mark the Word on the Page", isOn: $model.settings.showsTextOverlay)
                    RoundStepperRow("OCR pages ahead", value: Binding {
                        Double(model.settings.ocrAhead)
                    } set: {
                        model.settings.ocrAhead = Int($0.rounded())
                    }, in: 0...10, step: 1) { "\(Int($0))" }
                } header: {
                    Text("Text Lookup")
                } footer: {
                    Text("Tap text on a page to look it up. Long-press and drag to read any area.")
                }
                Section {
                    Button("Use for All Series") { model.saveSettingsAsDefault() }
                } footer: {
                    Text("Settings apply to this series. Use for All Series makes them the default for others.")
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
        #if os(iOS)
        // On the iPad a medium sheet is a small box showing only the first rows: full height there.
        .presentationDetents(sizeClass == .regular ? [.large] : [.medium, .large])
        #else
        .presentationDetents([.medium, .large])
        .frame(minWidth: 380, minHeight: 460)
        #endif
    }
}

/// Tap to Turn Pages: the usual sides, swapped, or off (both readers' settings).
struct TapZonesPicker: View {
    @Binding var selection: ReaderTapZones

    var body: some View {
        Picker("Tap to Turn Pages", selection: $selection) {
            Text("On").tag(ReaderTapZones.standard)
            Text("Sides Swapped").tag(ReaderTapZones.inverted)
            Text("Off").tag(ReaderTapZones.off)
        }
        .accessibilityIdentifier("reader.tapZones")
    }
}

/// Lock Rotation (iPhone and iPad), in both readers' settings.
struct RotationLockToggle: View {
    #if os(iOS)
    @State private var isOn = OrientationLock.isOn
    #endif

    var body: some View {
        #if os(iOS)
        Toggle("Lock Rotation", isOn: $isOn)
            .onChange(of: isOn) { _, on in OrientationLock.isOn = on }
            .accessibilityIdentifier("reader.lockRotation")
        #endif
    }
}
