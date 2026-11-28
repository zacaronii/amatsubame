import Core
import Dictionary
import HachidoriKit
import SwiftUI
import UniformTypeIdentifiers

public struct DictionariesView: View {
    @Environment(CommonEnvironment.self) private var environment
    @State private var records: [DictionaryRecord] = []
    /// The ones that update themselves ("Auto").
    @State private var selfUpdating: Set<String> = []
    @State private var frequencySort: String?
    @State private var frequencySortOrder = "auto"
    @State private var showsFileImporter = false
    @State private var showsURLPrompt = false
    @State private var urlText = ""
    @State private var importing: ImportProgress?
    @State private var message: String?
    /// While linked to Hachidori: send each imported zip to it too (#36).
    @AppStorage("dictionaries.sendsImportsToHachidori") private var sendsImportsToHachidori = false

    struct ImportProgress: Equatable {
        var name: String
        var verb = "Importing"
        var started = Date()
    }

    public init() {}

    public var body: some View {
        List {
            if let message {
                Section { Text(message).font(.callout) }
            }
            Section {
                ForEach(Array(records.enumerated()), id: \.element.id) { index, record in
                    DictionaryRow(record: record, updatesItself: selfUpdating.contains(record.id),
                                  problem: DictionaryFormat(folder: environment.dictionaries.folder(for: record)).problem) { enabled in
                        Task { await run { try await environment.dictionaries.setEnabled(record.id, enabled) } }
                    }
                    .reorderMenu(index: index, count: records.count, move: move)
                }
                .onMove(perform: move)
                .onDelete(perform: delete)
            } header: {
                Text("Installed")
            } footer: {
                Text("Results list dictionaries in this order. \(ReorderMenu.hint)")
            }
            let frequencyDictionaries = records.filter { $0.hasFrequencies && $0.enabled }
            if !frequencyDictionaries.isEmpty {
                // Hachidori's Frequency sorting: nothing sorts unless a dictionary and a direction are chosen.
                Section {
                    Picker("Sort by Frequency Dictionary", selection: $frequencySort) {
                        Text("None").tag(String?.none)
                        ForEach(frequencyDictionaries) { Text($0.title).tag(Optional($0.title)) }
                    }
                    .onChange(of: frequencySort) { old, title in
                        guard old != title, title != (try? environment.dictionaries.settings().frequencySortTitle) else { return }
                        Task {
                            await run { try await environment.dictionaries.setFrequencySortDictionary(title) }
                            loadFrequencySort()
                        }
                    }
                    Picker("Sort Order", selection: $frequencySortOrder) {
                        Text("Automatic — Dictionary Order").tag("auto")
                        Text("Ascending — Lowest Number First").tag("ascending").selectionDisabled(frequencySort == nil)
                        Text("Descending — Highest Number First").tag("descending").selectionDisabled(frequencySort == nil)
                        Text("Disabled").tag("disabled")
                    }
                    .onChange(of: frequencySortOrder) { old, order in
                        guard old != order, order != (try? environment.dictionaries.frequencySortSettings().order) else { return }
                        Task { await run { try await environment.dictionaries.setFrequencySortOrder(order) } }
                    }
                } header: {
                    Text("Frequency Sorting")
                } footer: {
                    Text(environment.hachidori == nil
                         ? "Choosing a dictionary sorts by its numbers, in the direction it declares. Automatic keeps your dictionary order, as Hachidori does by default."
                         : "While Hachidori is linked, its own frequency sorting applies.")
                }
            }
            CharacterNamesSection()
            DictionaryUpdatesSection()
            if let hachidori = environment.hachidori {
                Section {
                    NavigationLink {
                        HachidoriDictionariesPage()
                    } label: {
                        Label("Copy from Hachidori…", systemImage: "arrow.down.circle")
                    }
                    .disabled(!hachidori.isLinked)
                    .accessibilityIdentifier("dictionaries.copyFromHachidori")
                    Toggle("Also Add Imports to Hachidori", isOn: $sendsImportsToHachidori)
                        .accessibilityIdentifier("dictionaries.sendsImportsToHachidori")
                } header: {
                    Text("Hachidori")
                } footer: {
                    Text(hachidori.isLinked
                         ? "Copy Hachidori's dictionaries at its exact versions, with its order and on/off. Dictionary files you import here can go to Hachidori too."
                         : "Hachidori isn't reachable right now.")
                }
            }
            Section {
                NavigationLink {
                    AddRecommendedView()
                } label: {
                    Label("Add Recommended…", systemImage: "sparkles")
                }
                .accessibilityIdentifier("dictionaries.addRecommended")
                Button("Import from Files…", systemImage: "folder") { showsFileImporter = true }
                    .textButtonTint()
                Button("Import from URL…", systemImage: "link") { showsURLPrompt = true }
                    .textButtonTint()
            } footer: {
                Text("Yomitan dictionary zips: term dictionaries (Jitendex), frequency lists (Jiten) and pitch accent dictionaries.")
            }
        }
        .settingsListWidth()
        .navigationTitle("Dictionaries")
        .toolbar {
            #if os(iOS)
            EditButton().textButtonTint()
            #endif
        }
        .disabled(importing != nil)
        .overlay {
            if let importing {
                TimelineView(.periodic(from: importing.started, by: 1)) { context in
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("\(importing.verb) \(importing.name)…")
                        Text("\(Int(context.date.timeIntervalSince(importing.started)))s").monospacedDigit().foregroundStyle(.secondary)
                    }
                    .padding(24)
                    .background(.regularMaterial, in: .rect(cornerRadius: 16))
                }
            }
        }
        .fileImporter(isPresented: $showsFileImporter, allowedContentTypes: [.zip], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            Task { for url in urls { await importFile(url) } }
        }
        .alert("Import from URL", isPresented: $showsURLPrompt) {
            TextField("https://…/dictionary.zip", text: $urlText)
                #if os(iOS)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                #endif
            Button("Import") { Task { await importFromURL() } }
            Button("Cancel", role: .cancel) {}
        }
        .task { await observe() }
        .task { loadFrequencySort() }
    }

    private func loadFrequencySort() {
        guard let settings = try? environment.dictionaries.frequencySortSettings() else { return }
        frequencySort = settings.title
        frequencySortOrder = settings.order
    }

    private func observe() async {
        do {
            for try await records in environment.dictionaries.observeDictionaries() {
                self.records = records
                selfUpdating = environment.dictionaryUpdater.selfUpdating()
            }
        } catch {}
    }

    private func importFile(_ url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        await importZip(url, name: url.deletingPathExtension().lastPathComponent)
    }

    private func importFromURL() async {
        guard let url = URL(string: urlText.trimmingCharacters(in: .whitespaces)), url.scheme?.hasPrefix("http") == true else {
            message = "That isn't a web address."
            return
        }
        importing = ImportProgress(name: url.lastPathComponent)
        do {
            let (file, response) = try await URLSession.shared.download(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            // Its own name in a folder of its own (Hachidori shows the name of a zip sent to it).
            let folder = file.deletingLastPathComponent().appending(path: UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let name = url.lastPathComponent.isEmpty ? "dictionary" : url.lastPathComponent
            let zip = folder.appending(path: name.lowercased().hasSuffix(".zip") ? name : name + ".zip")
            try FileManager.default.moveItem(at: file, to: zip)
            await importZip(zip, name: url.lastPathComponent)
            urlText = ""
        } catch {
            importing = nil
            message = "Download failed: \(error.localizedDescription)"
        }
    }

    private func importZip(_ url: URL, name: String) async {
        importing = ImportProgress(name: name)
        defer { importing = nil }
        do {
            let outcome = try await environment.dictionaries.importDictionary(at: url)
            try await environment.lookup.reload()
            let verb = outcome.replacedPrevious ? "Updated" : "Imported"
            message = "\(verb) \(outcome.dictionary.title) in \(String(format: "%.1f", outcome.seconds))s."
            if sendsImportsToHachidori, let link = environment.hachidori?.link {
                await send(url, title: outcome.dictionary.title, to: link)
            }
        } catch {
            message = error.localizedDescription
        }
    }

    /// Sends an imported zip to Hachidori, replacing its copy of the same title.
    private func send(_ zip: URL, title: String, to link: HachidoriLink) async {
        importing = ImportProgress(name: "\(title) to Hachidori", verb: "Sending")
        do {
            try await link.sendDictionary(zip, replace: true)
            message = (message ?? "") + " Added it to Hachidori too."
        } catch {
            message = (message ?? "") + " Couldn't add it to Hachidori: \(error.localizedDescription)"
        }
    }

    private func move(from source: IndexSet, to destination: Int) {
        var ids = records.map(\.id)
        ids.move(fromOffsets: source, toOffset: destination)
        records.move(fromOffsets: source, toOffset: destination)
        Task { await run { try await environment.dictionaries.reorder(ids) } }
    }

    private func delete(at offsets: IndexSet) {
        let ids = offsets.map { records[$0].id }
        Task { await run { for id in ids { try await environment.dictionaries.delete(id) } } }
    }

    private func run(_ action: () async throws -> Void) async {
        do {
            try await action()
            try await environment.lookup.reload()
        } catch {
            message = error.localizedDescription
        }
    }
}

private struct DictionaryRow: View {
    let record: DictionaryRecord
    let updatesItself: Bool
    /// Why the engine can't load it (a newer format, or a broken folder).
    let problem: String?
    let onToggle: (Bool) -> Void

    var body: some View {
        Toggle(isOn: Binding(get: { record.enabled }, set: onToggle)) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(record.title)
                    HStack(spacing: 6) {
                        ForEach(kinds, id: \.self) { kind in
                            Text(kind)
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(.tint.opacity(0.15), in: .capsule)
                        }
                        Text(details).font(.caption).foregroundStyle(.secondary)
                    }
                    if let problem {
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                if updatesItself {
                    Spacer()
                    Label("Auto", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption)
                        .foregroundStyle(.tint)
                        .accessibilityLabel("Updates itself")
                }
            }
        }
        .accessibilityIdentifier("dictionary.\(record.title)")
    }

    private var kinds: [String] {
        [record.hasTerms ? "Terms" : nil, record.hasFrequencies ? "Frequency" : nil,
         record.hasPitches ? "Pitch" : nil, record.hasKanji ? "Kanji" : nil].compactMap { $0 }
    }

    private var details: String {
        // A kanji dictionary (KANJIDIC) has no terms: count its kanji.
        let count = record.hasTerms ? "\(record.termCount.formatted()) entries"
            : record.hasKanji ? "\(record.kanjiCount.formatted()) kanji" : "\(record.metaCount.formatted()) entries"
        return "\(count) · \(record.bytes.storageText)"
    }
}
