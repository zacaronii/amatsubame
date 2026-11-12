import Core
import Dictionary
import Lookup
import SwiftUI

public struct SearchView: View {
    enum Mode: String, CaseIterable {
        case word = "Word"
        case sentence = "Sentence"
    }

    @Environment(CommonEnvironment.self) private var environment
    @State private var mode = Mode.word
    @State private var query = ""
    @State private var popup: LookupPopupModel
    @State private var history: [LookupHistoryRecord] = []
    @State private var sentenceText = ""
    /// The search last counted in Stats, so leaving it on screen and submitting count once.
    @State private var countedQuery: String?
    @State private var editingSentence = true
    @State private var tapPopup: LookupPopupModel?
    @State private var hasDictionaries = true
    private let miningContext: (any MiningContext)?
    private let onDone: (() -> Void)?

    /// `miningContext` is attached to cards mined here (the Player passes the paused line);
    /// `onDone` adds a Done button, for showing Search in a sheet.
    public init(miningContext: (any MiningContext)? = nil, onDone: (() -> Void)? = nil) {
        self.miningContext = miningContext
        self.onDone = onDone
        _popup = State(initialValue: LookupPopupModel(context: miningContext))
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Mode", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.bottom, 8)

                if !hasDictionaries {
                    ContentUnavailableView {
                        Label("No Dictionaries", systemImage: "character.book.closed.ja")
                    } description: {
                        Text("Import Jitendex, a frequency list and a pitch dictionary in Settings → Dictionaries.")
                    }
                } else {
                    switch mode {
                    case .word: wordSearch
                    case .sentence: sentenceLookup
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            // At the stack's root: attached deeper, macOS broke navigation in the other tabs.
            .searchable(text: $query, prompt: "食べさせられなかった")
            .onChange(of: query) { _, text in
                if !text.isEmpty { mode = .word }
            }
            .navigationTitle("Dictionary")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                if let onDone {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", action: onDone)
                    }
                }
            }
        }
        .task { await observeHistory() }
        .task { await observeDictionaries() }
    }

    // MARK: Word search

    private var wordSearch: some View {
        Group {
            if query.isEmpty {
                List {
                    if !history.isEmpty {
                        Section {
                            ForEach(history) { entry in
                                Button {
                                    query = entry.expression
                                } label: {
                                    VStack(alignment: .leading) {
                                        Text(entry.expression).font(.title3)
                                        if entry.reading != entry.expression {
                                            Text(entry.reading).font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        } header: {
                            HStack {
                                Text("Recent")
                                Spacer()
                                Button("Clear") { environment.lookup.clearHistory() }.font(.caption)
                            }
                        }
                    }
                }
                .overlay {
                    if history.isEmpty {
                        ContentUnavailableView("Look Up a Word", systemImage: "magnifyingglass",
                                               description: Text("Type Japanese, or romaji (taberu, ko-hi-)."))
                    }
                }
            } else {
                LookupPopupView(service: environment.lookup, model: popup)
            }
        }
        .accessibilityIdentifier("search.word")
        .task(id: query) {
            guard !query.isEmpty else { return }
            try? await Task.sleep(for: .milliseconds(150))
            let page = await search(query)
            guard !Task.isCancelled else { return }
            popup.show(page)
            // A search left on screen counts as a lookup (once), like submitting it.
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            recordSearch(page)
        }
        .onSubmit(of: .search) {
            if let page = popup.current { recordSearch(page) }
        }
    }

    /// Japanese as typed; romaji as kana, hiragana first, then katakana (loanwords).
    private func search(_ query: String) async -> LookupResultPage {
        guard let hiragana = Romaji.hiragana(query) else { return await environment.lookup.search(query) }
        let page = await environment.lookup.search(hiragana)
        guard page.results.isEmpty, let katakana = Romaji.katakana(query) else { return page }
        let loanword = await environment.lookup.search(katakana)
        return loanword.results.isEmpty ? page : loanword
    }

    private func recordSearch(_ page: LookupResultPage) {
        guard countedQuery != page.query else { return }
        countedQuery = page.query
        environment.lookup.recordSearch(page)
    }

    // MARK: Sentence

    private var sentenceLookup: some View {
        VStack(spacing: 0) {
            if editingSentence {
                TextEditor(text: $sentenceText)
                    .font(.title3)
                    .padding(.horizontal)
                    .accessibilityIdentifier("search.sentenceEditor")
                    .overlay(alignment: .topLeading) {
                        if sentenceText.isEmpty {
                            Text("Paste Japanese text, then tap Done and tap any word.")
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 22)
                                .padding(.top, 8)
                                .allowsHitTesting(false)
                        }
                    }
            } else {
                TappableTextView(text: sentenceText, engine: environment.dictionaries.engine) { text, offset in
                    Task {
                        let page = await environment.lookup.lookup(text: text, utf16Offset: offset)
                        tapPopup = LookupPopupModel(page: page, context: miningContext)
                    }
                }
                .accessibilityIdentifier("search.tappableText")
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(editingSentence ? "Done" : "Edit") { editingSentence.toggle() }
                    .disabled(sentenceText.isEmpty)
                    .accessibilityIdentifier("search.sentenceDone")
            }
        }
        .sheet(item: $tapPopup) { model in
            NavigationStack {
                LookupPopupView(service: environment.lookup, model: model)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { tapPopup = nil }
                        }
                    }
            }
            .presentationDetents([.medium, .large])
            #if os(macOS)
            .frame(minWidth: 480, minHeight: 520)
            #endif
        }
    }

    private func observeHistory() async {
        do {
            for try await records in environment.lookup.observeHistory() { history = records }
        } catch {}
    }

    private func observeDictionaries() async {
        do {
            for try await records in environment.dictionaries.observeDictionaries() {
                hasDictionaries = records.contains { $0.enabled && $0.hasTerms }
            }
        } catch {}
    }
}
