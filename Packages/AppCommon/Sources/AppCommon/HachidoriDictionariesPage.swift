import Core
import Dictionary
import HachidoriKit
import Lookup
import SwiftUI

/// Settings ▸ Dictionaries ▸ Copy from Hachidori (#36): the host's dictionaries at its exact
/// revisions, then its order and on/off. Nothing downloads until the user asks.
@MainActor @Observable
final class HachidoriDictionaryCopy {
    struct Row: Identifiable, Equatable {
        enum State: Equatable {
            /// Not on this device.
            case new
            /// On this device at another revision (or under an older title).
            case update(installed: String?)
            /// On this device at Hachidori's revision.
            case same
            /// Hachidori can't export it (its personal dictionary, or a host without exports).
            case unavailable
        }

        let host: HostDictionary
        var state: State
        /// The dictionary on this device it replaces.
        var installedId: String?
        /// The fraction downloaded while copying.
        var progress: Double?
        var error: String?

        var id: String { host.id }
        var needsCopy: Bool { state == .new || { if case .update = state { true } else { false } }() }
    }

    private(set) var rows: [Row] = []
    /// On this device but not on Hachidori: they stay, after Hachidori's.
    private(set) var localOnly: [DictionaryRecord] = []
    private(set) var loaded = false
    private(set) var isCopying = false
    private(set) var message: String?

    private let environment: CommonEnvironment

    init(environment: CommonEnvironment) {
        self.environment = environment
    }

    var toCopy: Int { rows.filter(\.needsCopy).count }

    private var exports: HostDictionaryExports? {
        guard let link = environment.hachidori?.link else { return nil }
        return HostDictionaryExports.apiURL(forLink: link.url).map { HostDictionaryExports(baseURL: $0) }
    }

    func load() async {
        defer { loaded = true }
        guard let host = environment.hachidori, host.isLinked, let exports else {
            message = "Hachidori isn't linked. Check Settings ▸ Hachidori."
            return
        }
        let exportable: Set<String>
        do {
            exportable = Set(try await exports.list().map(\.id))
        } catch {
            message = "Couldn't get Hachidori's dictionaries: \(error.localizedDescription)"
            return
        }
        let local = (try? environment.dictionaries.dictionaries()) ?? []
        let sources = (try? environment.dictionaries.sources()) ?? [:]
        rows = host.dictionaries.map { dictionary in
            let installed = Self.match(dictionary, in: local, sources: sources)
            let state: Row.State = !exportable.contains(dictionary.id) ? .unavailable
                : installed == nil ? .new
                : installed?.revision == dictionary.revision && installed?.title == dictionary.title ? .same
                : .update(installed: installed?.revision)
            return Row(host: dictionary, state: state, installedId: installed?.id)
        }
        let matched = Set(rows.compactMap(\.installedId))
        localOnly = local.filter { !matched.contains($0.id) }
        message = nil
    }

    /// The device's copy of a host dictionary: the same title, or the same download link (a
    /// newer release can carry its date in its title, like Jitendex).
    static func match(_ dictionary: HostDictionary, in local: [DictionaryRecord],
                      sources: [String: DictionarySource]) -> DictionaryRecord? {
        local.first { $0.title == dictionary.title }
            ?? dictionary.downloadUrl.flatMap { url in local.first { sources[$0.id]?.downloadUrl == url } }
    }

    /// Downloads what's new or newer, then applies Hachidori's order and on/off.
    func copy() async {
        guard let exports, !isCopying else { return }
        isCopying = true
        defer { isCopying = false }
        message = nil
        for index in rows.indices where rows[index].needsCopy {
            rows[index].error = nil
            rows[index].progress = 0
            do {
                try await copy(rows[index], from: exports)
                rows[index].state = .same
            } catch {
                rows[index].error = error.localizedDescription
            }
            rows[index].progress = nil
        }
        await applyOrder()
        try? await environment.lookup.reload()
        await load()
        let failed = rows.filter { $0.error != nil }.count
        message = failed == 0 ? "Matches Hachidori." : "\(failed) couldn't be copied; the others match Hachidori."
    }

    private func copy(_ row: Row, from exports: HostDictionaryExports) async throws {
        let work = FileManager.default.temporaryDirectory.appending(path: "hachidori-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let zip = work.appending(path: "export.zip"), folder = work.appending(path: "dictionary")
        let id = row.id
        try await exports.download(id, to: zip) { fraction in
            Task { @MainActor [weak self] in self?.setProgress(fraction, for: id) }
        }
        // Unpacking a large dictionary takes a moment: off the main thread.
        try await Task.detached { try HostDictionaryExports.unpack(zip, into: folder) }.value
        try? FileManager.default.removeItem(at: zip)
        let host = row.host
        let kinds = DictionaryLibrary.CompiledKinds(terms: host.termCount ?? 0, frequencies: host.frequencyCount ?? 0,
                                                    pitches: host.pitchCount ?? 0, kanji: host.kanjiCount ?? 0,
                                                    media: host.mediaCount ?? 0)
        try await environment.dictionaries.installCompiled(folder, kinds: kinds, replacing: row.installedId)
    }

    private func setProgress(_ fraction: Double, for id: String) {
        guard let index = rows.firstIndex(where: { $0.id == id }), rows[index].progress != nil else { return }
        rows[index].progress = fraction
    }

    /// Hachidori's order and on/off for the dictionaries both have; the device's own come after.
    private func applyOrder() async {
        let library = environment.dictionaries
        guard let local = try? library.dictionaries(), let sources = try? library.sources() else { return }
        var order: [String] = []
        for row in rows {
            guard let installed = Self.match(row.host, in: local, sources: sources), !order.contains(installed.id) else { continue }
            order.append(installed.id)
            if installed.enabled != row.host.enabled { try? await library.setEnabled(installed.id, row.host.enabled) }
        }
        order += local.map(\.id).filter { !order.contains($0) }
        try? await library.reorder(order)
    }
}

/// The page itself.
struct HachidoriDictionariesPage: View {
    @Environment(CommonEnvironment.self) private var environment
    @State private var copy: HachidoriDictionaryCopy?

    var body: some View {
        List {
            if let copy {
                if let message = copy.message {
                    Section { Text(message).font(.callout) }
                }
                if !copy.rows.isEmpty {
                    Section {
                        ForEach(copy.rows) { row in
                            HachidoriDictionaryRow(row: row)
                        }
                    } header: {
                        Text("On Hachidori")
                    } footer: {
                        Text("In Hachidori's order. A dictionary already at Hachidori's version isn't downloaded again.")
                    }
                }
                if !copy.localOnly.isEmpty {
                    Section {
                        ForEach(copy.localOnly) { Text($0.title) }
                    } header: {
                        Text("Only on This Device")
                    } footer: {
                        Text("These stay, after Hachidori's.")
                    }
                }
                if copy.loaded && !copy.rows.isEmpty {
                    Section {
                        Button {
                            Task { await copy.copy() }
                        } label: {
                            Text(copy.toCopy == 0 ? "Match Order and On/Off"
                                 : copy.toCopy == 1 ? "Copy 1 Dictionary" : "Copy \(copy.toCopy) Dictionaries")
                        }
                        .disabled(copy.isCopying)
                        .accessibilityIdentifier("hachidori.copy")
                    } footer: {
                        Text("Downloads Hachidori's own copies, ready to use: about two to five times the size of the dictionary files (Hachidori's five recommended ones take about 340 MB). Then the order and on/off follow Hachidori's.")
                    }
                }
            }
        }
        .overlay {
            if copy?.loaded != true { ProgressView() }
        }
        .navigationTitle("Copy from Hachidori")
        .task {
            let model = HachidoriDictionaryCopy(environment: environment)
            copy = model
            await model.load()
        }
    }
}

private struct HachidoriDictionaryRow: View {
    let row: HachidoriDictionaryCopy.Row

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(row.host.name)
                Spacer()
                status
            }
            if let progress = row.progress {
                ProgressView(value: progress)
            }
            if let error = row.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("hachidori.dictionary.\(row.host.title)")
    }

    @ViewBuilder private var status: some View {
        switch row.state {
        case .same:
            Label("On This Device", systemImage: "checkmark.circle.fill")
                .labelStyle(.iconOnly)
                .foregroundStyle(.green)
                .accessibilityLabel("On this device")
        case .new:
            Text("New").font(.caption).foregroundStyle(.tint)
        case .update(let installed):
            Text(installed.map { "Update from \($0)" } ?? "Update").font(.caption).foregroundStyle(.tint)
        case .unavailable:
            Text("Can't Be Copied").font(.caption).foregroundStyle(.secondary)
        }
    }
}
