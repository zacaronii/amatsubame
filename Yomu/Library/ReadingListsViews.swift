import Core
import KavitaKit
import SwiftUI

/// The Library home's Reading Lists: the account's own and the ones others promoted, as Kavita
/// keeps them.
struct ReadingListsSection: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var lists: [ReadingListRow] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !lists.isEmpty {
                Text("Reading Lists").font(.title2.bold())
                    .accessibilityIdentifier("home.readingLists")
                VStack(spacing: 0) {
                    ForEach(lists) { list in
                        NavigationLink(value: list) {
                            HStack {
                                Text(list.title).lineLimit(1)
                                if !list.isEditable {
                                    Image(systemName: "lock").font(.caption).foregroundStyle(.secondary).accessibilityLabel("Read-only")
                                }
                                Spacer()
                                Text(list.state == .pendingCreate ? "Not on Kavita yet" : list.kavitaItemCount.map(String.init) ?? "")
                                    .font(.callout).foregroundStyle(.secondary)
                                Image(systemName: "chevron.forward").font(.caption).foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 10)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("readingList.\(list.title)")
                        if list.id != lists.last?.id { Divider() }
                    }
                }
                .padding(.horizontal)
                .background(.background.secondary, in: .rect(cornerRadius: 12))
            }
        }
        .task(id: environment.readerMarkAccount()) {
            guard let account = environment.readerMarkAccount() else { return }
            do {
                for try await rows in environment.readingLists.observe(account: account) {
                    let available = (try? environment.readerMarks.isAvailable(.readingLists, account: account)) ?? true
                    lists = available ? rows : []
                }
            } catch {}
        }
    }
}

/// A reading list's items in order. Own lists: drag to reorder, swipe to take out, Delete Reading
/// List in the top bar. Items Yomu can't open are dimmed with the reason.
struct ReadingListView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    let list: ReadingListRow
    @State private var items: [ReadingListItemRow] = []
    @State private var error: String?
    @State private var confirmsDelete = false
    @State private var lastItem: ReadingListItemRow?
    @State private var cantOpen: String?

    var body: some View {
        List {
            if let note = CollectionsSheet.readOnlyReason(list) ?? error {
                Text(note).font(.callout).foregroundStyle(.secondary)
            }
            ForEach(items, id: \.chapterId) { item in
                row(item)
                    .moveDisabled(!list.isEditable)
                    .deleteDisabled(!list.isEditable)
            }
            .onMove { from, to in move(from, to) }
            .onDelete { offsets in takeOut(offsets) }
        }
        .navigationTitle(list.title)
        .toolbar {
            if list.isEditable {
                ToolbarItem(placement: .primaryAction) {
                    Menu("More", systemImage: "ellipsis") {
                        Button("Delete Reading List", systemImage: "trash", role: .destructive) { confirmsDelete = true }
                            .accessibilityIdentifier("readingList.delete")
                    }
                    .accessibilityIdentifier("readingList.more")
                }
                #if os(iOS)
                ToolbarItem(placement: .topBarTrailing) { EditButton().accessibilityIdentifier("readingList.edit") }
                #endif
            }
        }
        .confirmationDialog("Delete \u{201C}\(list.title)\u{201D}?", isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button("Delete Reading List", role: .destructive) {
                guard let id = list.id else { return }
                try? environment.readingLists.delete(id, outbox: environment.outbox)
                environment.syncNow()
                dismiss()
            }
        } message: {
            Text("It's deleted on Kavita too. The series stay in your library.")
        }
        .alert("Take Out the Last Item?", isPresented: Binding { lastItem != nil } set: { if !$0 { lastItem = nil } }, presenting: lastItem) { item in
            Button("Cancel", role: .cancel) {}
            Button("Take Out", role: .destructive) { remove(item) }
        } message: { _ in
            Text("The list stays, empty. Kavita removes empty reading lists when it cleans up (daily, unless your server is set otherwise).")
        }
        .alert("Can't Open It", isPresented: Binding { cantOpen != nil } set: { if !$0 { cantOpen = nil } }) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(cantOpen ?? "")
        }
        .task {
            guard let id = list.id else { return }
            Task {
                do {
                    error = try await environment.refreshItems(of: list) ? nil : "Kavita no longer has this reading list."
                } catch {
                    self.error = "Offline: showing what's on this device."
                }
            }
            do {
                for try await rows in environment.readingLists.observeItems(listId: id) { items = rows }
            } catch {}
        }
    }

    /// Why Yomu can't open an item, if it can't.
    private func reason(_ item: ReadingListItemRow) -> String? {
        if item.format == 4 { return "PDF: open it in Kavita" }
        if item.format == 0 { return "Images: open it in Kavita" }
        if environment.hiddenLibraries.contains(item.libraryId) { return "In a library you've turned off in Settings" }
        return nil
    }

    private func row(_ item: ReadingListItemRow) -> some View {
        let reason = reason(item)
        return Button {
            if let reason {
                cantOpen = reason
                return
            }
            Task {
                do {
                    // Opened from the root, as a link is (presenting it from this list's screen
                    // kept SwiftUI laying out forever on iOS 26).
                    var opened = try await environment.session(chapterId: item.chapterId, seriesId: item.seriesId)
                    opened.readingListId = list.id
                    environment.requestedReader = opened
                } catch {
                    cantOpen = error.localizedDescription
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.seriesName.isEmpty ? item.title : item.seriesName).lineLimit(1)
                Text([item.seriesName.isEmpty ? nil : item.title, item.state == .pendingAdd ? "Not on Kavita yet" : nil, reason]
                    .compactMap(\.self).joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(reason == nil ? .primary : .secondary)
        .accessibilityIdentifier("readingList.item.\(item.chapterId)")
    }

    private func move(_ from: IndexSet, _ to: Int) {
        guard let id = list.id, let source = from.first else { return }
        var order = items.map(\.chapterId)
        let moved = order[source]
        order.move(fromOffsets: from, toOffset: to)
        guard let index = order.firstIndex(of: moved) else { return }
        try? environment.readingLists.move(moved, after: index > 0 ? order[index - 1] : nil, listId: id, outbox: environment.outbox)
        environment.syncNow()
    }

    private func takeOut(_ offsets: IndexSet) {
        guard let id = list.id else { return }
        for index in offsets {
            let item = items[index]
            // The note only when it's known to be the last one; nothing is deleted either way.
            if let count = try? environment.readingLists.itemCount(listId: id), count - 1 <= 0 {
                lastItem = item
            } else {
                remove(item)
            }
        }
    }

    private func remove(_ item: ReadingListItemRow) {
        guard let id = list.id else { return }
        let chapter = ReadingListChapter(chapterId: item.chapterId, seriesId: item.seriesId, volumeId: item.volumeId, libraryId: item.libraryId,
                                         format: item.format, seriesName: item.seriesName, title: item.title)
        try? environment.readingLists.set(false, chapter: chapter, listId: id, outbox: environment.outbox)
        environment.syncNow()
    }
}

/// A volume's or chapter's menu ▸ Add to Reading List…: own lists (a check for the ones it's in, as
/// far as this device knows), and New Reading List… to make one with it. Taking out is done in the
/// list itself.
struct ReadingListsSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    let chapter: ReadingListChapter
    @State private var lists: [ReadingListRow] = []
    @State private var naming = false
    @State private var newTitle = ""
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(lists.filter(\.isOwn)) { list in
                        let isIn = (try? environment.readingLists.item(listId: list.id ?? -1, chapterId: chapter.chapterId))??.isIn == true
                        Button {
                            guard list.isEditable, !isIn, let id = list.id else { return }
                            do {
                                try environment.readingLists.set(true, chapter: chapter, listId: id, outbox: environment.outbox)
                                environment.syncNow()
                                dismiss()
                            } catch {
                                problem = error.localizedDescription
                            }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(list.title)
                                    if !list.isEditable {
                                        Text("Synced from outside Kavita: change it there.").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if isIn { Image(systemName: "checkmark").foregroundStyle(.tint) }
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(list.isEditable && !isIn ? .primary : .secondary)
                        .accessibilityValue(isIn ? "In it" : "")
                        .accessibilityIdentifier("readingLists.row.\(list.title)")
                    }
                    Button("New Reading List…", systemImage: "plus") {
                        newTitle = ""
                        naming = true
                    }
                    .accessibilityIdentifier("readingLists.new")
                } footer: {
                    Text("Reading lists are kept on Kavita. To take something out, open the list.")
                }
            }
            .navigationTitle("Add to Reading List")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .alert("New Reading List", isPresented: $naming) {
                TextField("Title", text: $newTitle)
                Button("Cancel", role: .cancel) {}
                Button("Make") { make() }
            } message: {
                Text("\u{201C}\(chapter.title)\u{201D} goes in it.")
            }
            .alert("Couldn't Add It", isPresented: Binding { problem != nil } set: { if !$0 { problem = nil } }) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(problem ?? "")
            }
        }
        .task(id: environment.readerMarkAccount()) {
            guard let account = environment.readerMarkAccount() else { return }
            do {
                for try await rows in environment.readingLists.observe(account: account) { lists = rows }
            } catch {}
        }
    }

    private func make() {
        guard let account = environment.readerMarkAccount() else { return }
        do {
            try environment.readingLists.create(title: newTitle, with: chapter, account: account, outbox: environment.outbox)
            environment.syncNow()
            dismiss()
        } catch {
            problem = error.localizedDescription
        }
    }
}
