import Dictionary
import SwiftUI

/// The shared lookup popup: a stack of result pages so tapping a word inside a
/// definition opens it, with Back to return. Readers present this as a sheet or
/// overlay; the Search screen embeds it.
@MainActor @Observable
public final class LookupPopupModel: Identifiable {
    public private(set) var pages: [LookupResultPage] = []
    public var current: LookupResultPage? { pages.last }
    public var canGoBack: Bool { pages.count > 1 }
    /// Picture and source for cards mined from this popup (set by readers).
    public var context: (any MiningContext)?
    /// Results mined while the popup is open, per page.
    var minedIndices: [LookupResultPage.ID: Set<Int>] = [:]
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
    }

    func document(for page: LookupResultPage, service: LookupService) -> String {
        if let cached = documents[page.id] { return cached }
        let html = service.document(for: page)
        documents[page.id] = html
        return html
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
    @State private var toast: Toast?
    @State private var duplicate: (page: LookupResultPage, index: Int)?

    struct Toast: Equatable {
        var id = UUID()
        var text: String
        var jobId: Int64?
    }

    public init(service: LookupService, model: LookupPopupModel, showsBackBar: Bool = true) {
        self.service = service
        self.model = model
        self.showsBackBar = showsBackBar
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
                Divider()
            }
            if let page = model.current {
                LookupWebView(html: model.document(for: page, service: service), engine: service.library.engine,
                              minedIndices: model.minedIndices[page.id] ?? []) { event in
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
                let next = await service.search(query)
                service.record(next)
                model.push(next)
            }
        case .audio(let index):
            guard page.results.indices.contains(index) else { return }
            let result = page.results[index]
            service.audio.play(term: result.expression, reading: result.reading)
        case .mine(let index):
            mine(index, on: page, allowDuplicate: false)
        }
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
