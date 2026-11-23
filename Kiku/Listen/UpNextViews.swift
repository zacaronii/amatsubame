import AppCommon
import Core
import SwiftUI

/// Listen's Up Next: the next few, and Edit for the whole list.
struct UpNextShelf: View {
    @Environment(KikuEnvironment.self) private var environment
    static let shown = 3

    var body: some View {
        let items = environment.upNextFlat
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Up Next").font(.title2.bold())
                Spacer()
                SplitLink(items.count > Self.shown ? "See All \(items.count)" : "Edit", value: ListenRoute.upNext)
                    .accessibilityIdentifier("upNext.edit")
            }
            VStack(spacing: 0) {
                ForEach(Array(items.prefix(Self.shown).enumerated()), id: \.element.item.key) { index, row in
                    if index > 0 { Divider().padding(.leading, 68) }
                    UpNextRow(item: row.item, libraryId: row.libraryId)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
            .background(.background.secondary, in: .rect(cornerRadius: 20))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("listen.upNext")
    }
}

/// An episode in Up Next: tap to play it (it leaves the queue as it starts).
struct UpNextRow: View {
    @Environment(KikuEnvironment.self) private var environment
    let item: UpNextItem
    let libraryId: String

    var body: some View {
        Button { environment.playUpNextItem(item, libraryId: libraryId) } label: {
            HStack(spacing: 12) {
                ShowCover(itemId: item.itemId, cornerRadius: 8).frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                    Text(item.showTitle).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Remove from Up Next", systemImage: "minus.circle", role: .destructive) {
                environment.removeFromUpNext(item, libraryId: libraryId)
            }
        }
        .accessibilityIdentifier("upNext.item")
    }
}

/// The whole Up Next: drag to reorder, swipe to remove, Clear.
struct UpNextView: View {
    @Environment(KikuEnvironment.self) private var environment
    @State private var confirmsClear = false

    var body: some View {
        let libraries = environment.upNext.keys.sorted()
        List {
            ForEach(libraries, id: \.self) { libraryId in
                Section(libraries.count > 1 ? (environment.library.libraries.first { $0.id == libraryId }?.name ?? "") : "") {
                    ForEach(environment.upNext[libraryId] ?? [], id: \.key) { item in
                        UpNextRow(item: item, libraryId: libraryId)
                    }
                    .onMove { environment.moveUpNext(from: $0, to: $1, libraryId: libraryId) }
                    .onDelete { offsets in
                        let items = environment.upNext[libraryId] ?? []
                        for index in offsets where items.indices.contains(index) { environment.removeFromUpNext(items[index], libraryId: libraryId) }
                    }
                }
            }
        }
        .overlay {
            if environment.upNext.isEmpty {
                ContentUnavailableView("Nothing Up Next", systemImage: "text.line.first.and.arrowtriangle.forward",
                                       description: Text("Choose Play Next or Play Last in an episode's menu."))
            }
        }
        .navigationTitle("Up Next")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Clear", systemImage: "trash", role: .destructive) { confirmsClear = true }
                    .disabled(environment.upNext.isEmpty)
                    .accessibilityIdentifier("upNext.clear")
                #if os(iOS)
                EditButton()
                #endif
            }
        }
        .confirmationDialog("Clear Up Next?", isPresented: $confirmsClear, titleVisibility: .visible) {
            Button("Clear Up Next", role: .destructive) {
                for libraryId in environment.upNext.keys { environment.clearUpNext(libraryId: libraryId) }
            }
        } message: {
            Text("This also clears the Up Next playlist on Audiobookshelf.")
        }
    }
}
