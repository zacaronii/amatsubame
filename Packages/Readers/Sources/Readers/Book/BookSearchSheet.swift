import SwiftUI

/// Search in the book: results by chapter, each with a little text either side and the match in
/// bold; tapping one goes there and marks it. The query stays while the reader is open.
struct BookSearchSheet: View {
    @Bindable var model: BookReaderModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                switch model.searchState {
                case .idle:
                    EmptyView()
                case .preparing(let fraction):
                    // The first search in a book reads its text once (it's kept on this device).
                    ProgressView("Preparing search…", value: fraction)
                        .accessibilityIdentifier("bookSearch.preparing")
                case .failed(let message):
                    Text(message).foregroundStyle(.secondary)
                case .ready:
                    results
                }
            }
            #if os(iOS)
            .searchable(text: $model.searchQuery, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search the Book")
            #else
            .searchable(text: $model.searchQuery, prompt: "Search the Book")
            #endif
            .onSubmit(of: .search) { Task { await model.search() } }
            .task(id: model.searchQuery) {
                // A moment after typing stops.
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                await model.search()
            }
            .navigationTitle("Search")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    @ViewBuilder private var results: some View {
        let hits = model.searchHits
        if model.searchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
            EmptyView()
        } else if hits.isEmpty {
            ContentUnavailableView.search(text: model.searchQuery)
        } else {
            Text(hits.count >= BookSearch.limit ? "Showing the first \(BookSearch.limit) results" : "\(hits.count) results")
                .font(.footnote).foregroundStyle(.secondary)
                .accessibilityIdentifier("bookSearch.count")
            ForEach(Self.grouped(hits), id: \.section) { group in
                Section(model.sectionTitle(group.section)) {
                    ForEach(group.hits) { hit in
                        Button {
                            model.jump(to: hit)
                            dismiss()
                        } label: {
                            Text(Self.snippet(hit)).lineLimit(2)
                        }
                        .accessibilityIdentifier("bookSearch.result")
                    }
                }
            }
        }
    }

    static func grouped(_ hits: [BookSearch.Hit]) -> [(section: Int, hits: [BookSearch.Hit])] {
        var groups: [(section: Int, hits: [BookSearch.Hit])] = []
        for hit in hits {
            if groups.last?.section == hit.section { groups[groups.count - 1].hits.append(hit) } else { groups.append((hit.section, [hit])) }
        }
        return groups
    }

    static func snippet(_ hit: BookSearch.Hit) -> AttributedString {
        var before = AttributedString((hit.before.count >= 20 ? "…" : "") + hit.before)
        var match = AttributedString(hit.match)
        match.inlinePresentationIntent = .stronglyEmphasized
        match.foregroundColor = .accentColor
        let after = AttributedString(hit.after + (hit.after.count >= 20 ? "…" : ""))
        before.append(match)
        before.append(after)
        return before
    }
}

/// The reader's side of search: the sheet, ⇧⌘F, and after a jump the way back to where you were
/// (until you read on from there).
struct BookSearchSupport: ViewModifier {
    let model: BookReaderModel
    @Binding var showsSearch: Bool

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $showsSearch) { BookSearchSheet(model: model) }
            .overlay(alignment: .bottom) {
                if model.searchBack != nil, model.state == .ready {
                    Button("Back to Where You Were", systemImage: "arrow.uturn.backward") { model.goBackFromSearch() }
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .glassEffect(.regular.interactive(), in: .capsule)
                        .buttonStyle(.plain)
                        .padding(.bottom, 40)
                        .accessibilityIdentifier("bookSearch.back")
                }
            }
            .background {
                // ⇧⌘F: ⌘F is Search Dictionary in Yomu's Reader menu (the Mac's menu would take it).
                Button("Search the Book") { showsSearch = true }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                    .opacity(0)
                    .accessibilityHidden(true)
                    .disabled(model.state != .ready)
            }
    }
}
