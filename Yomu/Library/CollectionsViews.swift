import Core
import KavitaKit
import SwiftUI

/// The Library home's Collections: the account's own and the ones others promoted, as Kavita
/// keeps them. Each opens as a grid of its series.
struct CollectionsSection: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var collections: [CollectionRow] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !collections.isEmpty {
                Text("Collections").font(.title2.bold())
                    .accessibilityIdentifier("home.collections")
                VStack(spacing: 0) {
                    ForEach(collections) { collection in
                        NavigationLink(value: collection) {
                            HStack {
                                Text(collection.title).lineLimit(1)
                                if !collection.isEditable {
                                    Image(systemName: "lock").font(.caption).foregroundStyle(.secondary)
                                        .accessibilityLabel("Read-only")
                                }
                                Spacer()
                                Text(collection.state == .pendingCreate ? "Not on Kavita yet" : "\(collection.itemCount)")
                                    .font(.callout).foregroundStyle(.secondary)
                                Image(systemName: "chevron.forward").font(.caption).foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 10)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("collection.\(collection.title)")
                        if collection.id != collections.last?.id { Divider() }
                    }
                }
                .padding(.horizontal)
                .background(.background.secondary, in: .rect(cornerRadius: 12))
            }
        }
        .task(id: environment.readerMarkAccount()) {
            guard let account = environment.readerMarkAccount() else { return }
            do {
                for try await rows in environment.collections.observe(account: account) {
                    let available = (try? environment.readerMarks.isAvailable(.collections, account: account)) ?? true
                    collections = available ? rows : []
                }
            } catch {}
        }
    }
}

/// One collection's series, filtered as the Want to Read shelf is; Delete for one's own.
struct CollectionView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    let collection: CollectionRow
    @State private var seriesIds: [Int] = []
    @State private var error: String?
    @State private var confirmsDelete = false

    var body: some View {
        let all = seriesIds.compactMap { try? environment.kavitaLibrary.cachedSeries(id: $0) }
        let readable = Set(((try? environment.kavitaLibrary.cachedLibraries()) ?? []).filter { $0.isMangaReadable || $0.isBookLibrary }.map(\.id))
        let offline = environment.isLibraryOffline
        let downloaded = environment.downloadedSeriesIds
        let shown = all.filter {
            readable.contains($0.libraryId) && !environment.hiddenLibraries.contains($0.libraryId) && (!offline || downloaded.contains($0.id))
        }
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let note = note(shown: shown.count) {
                    Text(note).font(.callout).foregroundStyle(.secondary)
                        .accessibilityIdentifier("collection.note")
                }
                if let error {
                    Label(error, systemImage: "wifi.exclamationmark").font(.callout).foregroundStyle(.secondary)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110, maximum: 180), spacing: 16)], spacing: 20) {
                    ForEach(shown) { series in
                        NavigationLink(value: series) { SeriesTile(series: series) }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("collection.series.\(series.name)")
                    }
                }
            }
            .padding()
        }
        .navigationTitle(collection.title)
        .toolbar {
            if collection.isEditable {
                ToolbarItem(placement: .primaryAction) {
                    Button("Delete Collection", systemImage: "trash", role: .destructive) { confirmsDelete = true }
                        .accessibilityIdentifier("collection.delete")
                }
            }
        }
        .confirmationDialog("Delete \u{201C}\(collection.title)\u{201D}?", isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button("Delete Collection", role: .destructive) {
                guard let id = collection.id else { return }
                try? environment.collections.delete(id, outbox: environment.outbox)
                environment.syncNow()
                dismiss()
            }
        } message: {
            Text("It's deleted on Kavita too. The series stay in your library.")
        }
        .task {
            guard let id = collection.id else { return }
            Task {
                do {
                    try await environment.refreshSeries(of: collection)
                    error = nil
                } catch {
                    self.error = "Offline: showing what's on this device."
                }
            }
            do {
                for try await ids in environment.collections.observeSeries(collectionId: id) { seriesIds = ids }
            } catch {}
        }
    }

    /// "3 of 5 series: the others are in libraries Yomu doesn't show", or why it's read-only.
    private func note(shown: Int) -> String? {
        var lines: [String] = []
        let total = max(seriesIds.count, collection.itemCount)
        if total > shown {
            lines.append(shown == 0
                ? "Its \(total) series are in libraries Yomu doesn't show (or aren't downloaded)."
                : "\(shown) of \(total) series: the others are in libraries Yomu doesn't show (or aren't downloaded).")
        }
        if let reason = CollectionsSheet.readOnlyReason(collection) { lines.append(reason) }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}

/// Series page ▸ Collections…: the own collections with a check for the ones holding this
/// series; New Collection… makes one with it. Read-only ones are listed with the reason.
struct CollectionsSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    let seriesId: Int
    @State private var collections: [CollectionRow] = []
    @State private var holding: Set<Int64> = []
    @State private var naming = false
    @State private var newTitle = ""
    @State private var problem: String?
    @State private var removingLast: CollectionRow?

    static func readOnlyReason(_ collection: CollectionRow) -> String? {
        if !collection.isOwn { return "Promoted by \(collection.owner ?? "another user"): read-only." }
        guard collection.source != 0 else { return nil }
        let from = [1: "AniList", 2: "MyAnimeList", 4: "CBR", 5: "Hardcover", 6: "MangaBaka"][collection.source] ?? "outside Kavita"
        return "Synced from \(from): change it there."
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(collections.filter(\.isOwn)) { collection in
                        row(collection)
                    }
                    Button("New Collection…", systemImage: "plus") {
                        newTitle = ""
                        naming = true
                    }
                    .accessibilityIdentifier("collections.new")
                } footer: {
                    Text("Collections are kept on Kavita. Kavita deletes a collection when its last series is taken out.")
                }
            }
            .navigationTitle("Collections")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .alert("New Collection", isPresented: $naming) {
                TextField("Title", text: $newTitle)
                    .accessibilityIdentifier("collections.newTitle")
                Button("Cancel", role: .cancel) {}
                Button("Make") { make() }
                    .accessibilityIdentifier("collections.make")
            } message: {
                Text("This series goes in it.")
            }
            .alert("Couldn't Make the Collection", isPresented: Binding { problem != nil } set: { if !$0 { problem = nil } }) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(problem ?? "")
            }
            .confirmationDialog("Take out the last series?", isPresented: Binding { removingLast != nil } set: { if !$0 { removingLast = nil } },
                                titleVisibility: .visible, presenting: removingLast) { collection in
                Button("Take Out and Delete \u{201C}\(collection.title)\u{201D}", role: .destructive) { toggle(collection, on: false) }
            } message: { _ in
                Text("Kavita deletes a collection when its last series is taken out.")
            }
        }
        .task(id: environment.readerMarkAccount()) {
            guard let account = environment.readerMarkAccount() else { return }
            Task { try? await environment.refreshMembership(of: seriesId) }
            Task {
                do {
                    for try await ids in environment.collections.observeCollections(ofSeries: seriesId, account: account) { holding = ids }
                } catch {}
            }
            do {
                for try await rows in environment.collections.observe(account: account) { collections = rows }
            } catch {}
        }
    }

    private func row(_ collection: CollectionRow) -> some View {
        let id = collection.id ?? -1
        let isIn = holding.contains(id)
        return Button {
            guard collection.isEditable else { return }
            if isIn, (try? environment.collections.seriesCount(collectionId: id)) ?? 2 <= 1 {
                removingLast = collection
            } else {
                toggle(collection, on: !isIn)
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(collection.title)
                    if let reason = Self.readOnlyReason(collection) {
                        Text(reason).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if isIn { Image(systemName: "checkmark").foregroundStyle(.tint) }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(collection.isEditable ? .primary : .secondary)
        .accessibilityValue(isIn ? "In it" : "")
        .accessibilityIdentifier("collections.row.\(collection.title)")
    }

    private func toggle(_ collection: CollectionRow, on: Bool) {
        guard let id = collection.id else { return }
        do {
            try environment.collections.set(on, seriesId: seriesId, collectionId: id, outbox: environment.outbox)
            environment.syncNow()
        } catch {
            problem = error.localizedDescription
        }
    }

    private func make() {
        guard let account = environment.readerMarkAccount() else { return }
        do {
            try environment.collections.create(title: newTitle, with: seriesId, account: account, outbox: environment.outbox)
            environment.syncNow()
        } catch {
            problem = error.localizedDescription
        }
    }
}
