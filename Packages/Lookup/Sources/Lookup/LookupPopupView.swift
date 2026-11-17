import Core
import Dictionary
import SwiftUI

/// The shared lookup popup: a stack of result pages so tapping a word inside a
/// definition opens it, with Back to return. Apps show it with `lookupOverlay` (a card by
/// the word, or a bottom panel); the Search screen embeds it.
@MainActor @Observable
public final class LookupPopupModel: Identifiable {
    public private(set) var pages: [LookupResultPage] = []
    public var current: LookupResultPage? { pages.last }
    public var canGoBack: Bool { pages.count > 1 }
    /// Picture and source for cards mined from this popup (set by readers).
    public var context: (any MiningContext)?
    /// The looked-up word on screen, in window coordinates: the popup goes beside it
    /// (`lookupOverlay`). Nil puts it along the bottom.
    public var anchor: CGRect?
    /// Results mined while the popup is open, per page.
    var minedIndices: [LookupResultPage.ID: Set<Int>] = [:]
    /// Lookup counts recorded after a page was shown (a search left on screen), per page.
    var lookupCounts: [LookupResultPage.ID: Int] = [:]
    /// Each page's HTML, built once so marking a result as mined doesn't reload it.
    @ObservationIgnored private var documents: [LookupResultPage.ID: String] = [:]

    public init(page: LookupResultPage? = nil, context: (any MiningContext)? = nil) {
        if let page { pages = [page] }
        self.context = context
    }

    public func show(_ page: LookupResultPage) {
        pages = [page]
        documents = [:]
        minedIndices = [:]
        lookupCounts = [:]
    }

    /// The count for a page recorded after it was shown.
    public func setLookupCount(_ count: Int?, for page: LookupResultPage.ID) {
        lookupCounts[page] = count
    }

    func document(for page: LookupResultPage, service: LookupService) -> String {
        if let cached = documents[page.id] { return cached }
        let html = service.document(for: page, nativeBackground: true)
        documents[page.id] = html
        return html
    }

    /// Every page's HTML but this one's is built again (a word's mark changed).
    func forgetDocuments(except page: LookupResultPage.ID) {
        documents = documents.filter { $0.key == page }
    }

    func forgetDocument(_ page: LookupResultPage.ID) {
        documents[page] = nil
        minedIndices[page] = nil
    }

    /// The sentence for a card: the page's own, or the first page's when the word came
    /// from a nested lookup (a definition) and isn't in it.
    func sentence(for result: TermLookupResult, on page: LookupResultPage) -> String? {
        let match = result.matched.isEmpty ? result.expression : result.matched
        if let sentence = page.sentence, sentence.contains(match) { return sentence }
        return pages.first?.sentence ?? page.sentence
    }

    public func push(_ page: LookupResultPage) {
        pages.append(page)
    }

    public func back() {
        guard canGoBack else { return }
        pages.removeLast()
    }
}

public struct LookupPopupView: View {
    let service: LookupService
    @Bindable var model: LookupPopupModel
    var showsBackBar = true
    var drawsBackground = true
    @State private var toast: Toast?
    @State private var duplicate: (page: LookupResultPage, index: Int)?

    struct Toast: Equatable {
        var id = UUID()
        var text: String
        var jobId: Int64?
    }

    /// `drawsBackground: false` when a wrapper around the popup (a header, a clip bar) draws
    /// `lookupPopupBackground` itself, so the tint covers it too.
    public init(service: LookupService, model: LookupPopupModel, showsBackBar: Bool = true, drawsBackground: Bool = true) {
        self.service = service
        self.model = model
        self.showsBackBar = showsBackBar
        self.drawsBackground = drawsBackground
    }

    public var body: some View {
        VStack(spacing: 0) {
            if showsBackBar, model.canGoBack {
                HStack {
                    Button("Back", systemImage: "chevron.backward") { model.back() }
                        .labelStyle(.titleAndIcon)
                        .accessibilityIdentifier("lookup.back")
                    Spacer()
                    if let query = model.current?.query {
                        Text(query).font(.headline).lineLimit(1)
                    }
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .lookupPopupTextHalo(service)
                Divider()
            }
            if let page = model.current {
                LookupWebView(html: model.document(for: page, service: service), media: .service(service),
                              minedIndices: model.minedIndices[page.id] ?? [],
                              lookupCount: model.lookupCounts[page.id]) { event in
                    handle(event, page: page)
                }
                .accessibilityIdentifier("lookup.results")
            } else {
                ContentUnavailableView("Look Up a Word", systemImage: "character.book.closed.ja",
                                       description: Text("Search, or tap any Japanese text."))
            }
        }
        .overlay(alignment: .bottom) {
            if let toast {
                MinedToast(toast: toast) { undo(toast) }
                    .task(id: toast.id) {
                        try? await Task.sleep(for: .seconds(MiningService.undoWindow))
                        if self.toast == toast { self.toast = nil }
                    }
            } else {
                AudioStatusBanner(status: service.audio.status)
            }
        }
        .animation(.default, value: toast)
        .modifier(PopupBackground(service: service, enabled: drawsBackground))
        .confirmationDialog("Already in Anki", isPresented: Binding(get: { duplicate != nil }, set: { if !$0 { duplicate = nil } }),
                            presenting: duplicate) { item in
            Button("Add Another Card") { mine(item.index, on: item.page, allowDuplicate: true) }
        } message: { _ in
            Text("This word is already in Anki or waiting to be sent.")
        }
    }

    private func mine(_ index: Int, on page: LookupResultPage, allowDuplicate: Bool) {
        guard let mining = service.mining, page.results.indices.contains(index) else { return }
        let result = page.results[index]
        if !allowDuplicate, mining.isMined(result) || model.minedIndices[page.id]?.contains(index) == true {
            duplicate = (page, index)
            return
        }
        // Checked at once: cutting a video clip takes a few seconds, and a second tap meanwhile
        // added the card twice.
        let wasMined = model.minedIndices[page.id]?.contains(index) == true
        model.minedIndices[page.id, default: []].insert(index)
        Task {
            do {
                let mined = try await mining.mine(result, sentence: model.sentence(for: result, on: page),
                                                  context: model.context, allowDuplicate: allowDuplicate)
                toast = Toast(text: "Added \(mined.expression)", jobId: mined.jobId)
            } catch {
                if !wasMined { model.minedIndices[page.id]?.remove(index) }
                toast = Toast(text: "Couldn't add the card: \(error.localizedDescription)")
            }
        }
    }

    private func undo(_ toast: Toast) {
        guard let jobId = toast.jobId, let mining = service.mining else { return }
        self.toast = mining.cancel(jobId) ? nil : Toast(text: "Already sent to Anki")
        // Rebuild the page so the button shows the word's real state again.
        if let page = model.current { model.forgetDocument(page.id) }
    }

    private func handle(_ event: LookupWebEvent, page: LookupResultPage) {
        switch event {
        case .tap(let text, let offset):
            Task {
                // A tap in the source header re-runs the lookup from there, keeping the header.
                let fromSource = page.source?.text == text
                let next = await service.lookup(text: text, utf16Offset: offset, showSource: fromSource)
                if !next.results.isEmpty { model.push(next) }
            }
        case .query(let query):
            Task {
                // A link in a definition is its own visit, so it counts (as in Hachidori).
                let next = await service.record(await service.search(query))
                model.push(next)
            }
        case .audio(let index):
            guard page.results.indices.contains(index) else { return }
            let result = page.results[index]
            service.audio.play(term: result.expression, reading: result.reading)
        case .mine(let index):
            mine(index, on: page, allowDuplicate: false)
        case .wordStatus(let index, let status):
            guard page.results.indices.contains(index) else { return }
            // The page already shows the change; the other pages are built again with it.
            service.toggleWordStatus(status, for: page.results[index].expression)
            model.forgetDocuments(except: page.id)
        }
    }
}

/// The popup's background: what's behind, blurred by the lightest material at full strength,
/// under the popup colour at the chosen opacity (Settings ▸ Popup, Hachidori's Background
/// opacity: a tint only). Behind the bar, the page (drawn transparent) and the bottom edge
/// alike, with a sheet's or popover's own background cleared so what's behind shows through.
/// (Fading the material instead cross-fades a sharp and a blurred copy of what's behind.)
struct PopupBackground: ViewModifier {
    let service: LookupService
    var enabled = true
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        if enabled {
            content
                .background(color.ignoresSafeArea())
                .background(.ultraThinMaterial)
                .presentationBackground(.clear)
        } else {
            content
        }
    }

    /// popup.css --background-color.
    private var color: Color {
        let base = colorScheme == .dark ? Color(red: 0x1c / 255, green: 0x1c / 255, blue: 0x1e / 255) : .white
        return base.opacity(Double(min(max(service.popupSettings.backgroundOpacityPercent, 0), 100)) / 100)
    }
}

/// A soft halo around text that sits on a see-through popup (popup.css `text-shadow`, the same
/// three layers): black in dark mode, white in light, strongest at 0 % opacity and gone by 70 %.
struct PopupTextHalo: ViewModifier {
    let service: LookupService
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let strength = LookupService.haloStrength(opacityPercent: service.popupSettings.backgroundOpacityPercent)
        let halo: Color = colorScheme == .dark ? .black : .white
        // A CSS blur radius is about twice SwiftUI's shadow radius.
        content
            .shadow(color: halo.opacity(0.95 * strength), radius: 0.5)
            .shadow(color: halo.opacity(0.75 * strength), radius: 1.5)
            .shadow(color: halo.opacity(0.60 * strength), radius: 3, y: 1)
    }
}

public extension View {
    /// For a wrapper around `LookupPopupView(…, drawsBackground: false)`: the popup's background
    /// behind the whole wrapper.
    func lookupPopupBackground(_ service: LookupService) -> some View {
        modifier(PopupBackground(service: service))
    }

    /// The popup's text halo, for native text on the popup's background (headers, bars).
    func lookupPopupTextHalo(_ service: LookupService) -> some View {
        modifier(PopupTextHalo(service: service))
    }
}

private struct MinedToast: View {
    let toast: LookupPopupView.Toast
    let undo: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(toast.text).lineLimit(2)
            if toast.jobId != nil {
                Button("Undo", action: undo)
                    .bold()
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .accessibilityIdentifier("lookup.undoMine")
            }
        }
        .font(.footnote)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        // Thick, outlined and shadowed so it stands out over a white page in light mode.
        .background(.thickMaterial, in: .capsule)
        .overlay(Capsule().strokeBorder(.separator))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
        .padding(.bottom, 12)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("lookup.minedToast")
    }
}

private struct AudioStatusBanner: View {
    let status: AudioService.Status

    var body: some View {
        Group {
            switch status {
            case .loading:
                Label("Loading audio…", systemImage: "speaker.wave.2")
            case .unavailable:
                Label("No audio", systemImage: "speaker.slash")
            case .idle, .playing:
                EmptyView()
            }
        }
        .font(.footnote)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: .capsule)
        .padding(.bottom, 12)
        .animation(.default, value: status)
        .accessibilityIdentifier("lookup.audioStatus")
    }
}
