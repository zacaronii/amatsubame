import Core
import SwiftUI

/// The recommended dictionaries, each with where it stands: installed, downloading, waiting,
/// or ready to pick. Settings ▸ Dictionaries ▸ Add Recommended and setup's dictionary step.
public struct RecommendedDictionaryRows: View {
    @Environment(CommonEnvironment.self) private var environment
    /// The ones to download (not installed yet).
    @Binding var selection: Set<String>
    let installed: Set<String>
    let removed: Set<String>

    public init(selection: Binding<Set<String>>, installed: Set<String>, removed: Set<String>) {
        _selection = selection
        self.installed = installed
        self.removed = removed
    }

    public var body: some View {
        ForEach(RecommendedDictionaries.all) { entry in
            row(entry)
        }
    }

    private func row(_ entry: RecommendedDictionary) -> some View {
        let state = environment.dictionaryUpdater.items[entry.id]
        let isInstalled = installed.contains(entry.id) || state == .installed
        return HStack(spacing: 12) {
            Image(systemName: "character.book.closed.ja")
                .font(.body)
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(.purple.gradient, in: .rect(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                Text(removed.contains(entry.id) && !isInstalled
                     ? "\(entry.purpose) · removed earlier"
                     : "\(entry.purpose) · \(entry.approximateBytes.storageText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            trailing(entry, state: state, installed: isInstalled)
        }
        .contentShape(.rect)
        .onTapGesture {
            guard !isInstalled, !environment.dictionaryUpdater.isInstalling else { return }
            if selection.contains(entry.id) { selection.remove(entry.id) } else { selection.insert(entry.id) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("recommended.\(entry.id)")
        .accessibilityValue(accessibilityValue(state: state, installed: isInstalled, selected: selection.contains(entry.id)))
        .accessibilityAddTraits(isInstalled ? [] : .isButton)
    }

    @ViewBuilder private func trailing(_ entry: RecommendedDictionary, state: DictionaryUpdater.ItemState?, installed: Bool) -> some View {
        if installed {
            Image(systemName: "checkmark").foregroundStyle(.tint).accessibilityLabel("Installed")
        } else {
            switch state {
            case .downloading(let fraction?):
                ProgressView(value: fraction).frame(width: 60)
            case .downloading(nil), .installing:
                ProgressView()
            case .waiting:
                Text("Waiting").font(.callout).foregroundStyle(.secondary)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityLabel("Failed")
            case .installed, nil:
                Image(systemName: selection.contains(entry.id) ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selection.contains(entry.id) ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
            }
        }
    }

    private func accessibilityValue(state: DictionaryUpdater.ItemState?, installed: Bool, selected: Bool) -> String {
        if installed { return "installed" }
        return switch state {
        case .downloading, .installing: "downloading"
        case .waiting: "waiting"
        case .failed(let message): "failed: \(message)"
        case .installed, nil: selected ? "selected" : "not selected"
        }
    }
}

/// Settings ▸ Dictionaries ▸ Add Recommended: pick and download, with the outcome.
struct AddRecommendedView: View {
    @Environment(CommonEnvironment.self) private var environment
    @State private var selection: Set<String> = []
    @State private var installed: Set<String> = []
    @State private var removed: Set<String> = []
    @State private var loaded = false

    var body: some View {
        let updater = environment.dictionaryUpdater
        Form {
            Section {
                RecommendedDictionaryRows(selection: $selection, installed: installed, removed: removed)
            } footer: {
                Text("Free dictionaries that most learners use. They're stored on this device, work offline and keep themselves up to date. Tap one to pick or unpick it.")
            }
            if let failure = failures.first {
                Section { Label(failure, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            }
            Section {
                Button(buttonTitle) {
                    Task {
                        await updater.installRecommended(Array(selection))
                        refresh()
                        selection = []
                    }
                }
                .disabled(selection.isEmpty || updater.isInstalling)
                .accessibilityIdentifier("recommended.download")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Recommended")
        .onAppear {
            refresh()
            guard !loaded else { return }
            loaded = true
            // Everything not installed yet, except ones the user removed.
            selection = Set(RecommendedDictionaries.all.map(\.id)).subtracting(installed).subtracting(removed)
        }
    }

    private var buttonTitle: String {
        let updater = environment.dictionaryUpdater
        if updater.isInstalling {
            let total = updater.items.count
            let done = updater.items.values.filter { $0 == .installed }.count
            return "Downloading… \(min(done + 1, total)) of \(total)"
        }
        return selection.count == 1 ? "Download 1 Dictionary" : "Download \(selection.count) Dictionaries"
    }

    private var failures: [String] {
        environment.dictionaryUpdater.items.compactMap { id, state in
            guard case .failed(let message) = state else { return nil }
            return "\(RecommendedDictionaries.entry(id)?.name ?? id): \(message)"
        }
    }

    private func refresh() {
        installed = environment.dictionaryUpdater.installedRecommended()
        removed = environment.dictionaryUpdater.removedRecommended()
    }
}

/// Settings ▸ Dictionaries ▸ Updates.
struct DictionaryUpdatesSection: View {
    @Environment(CommonEnvironment.self) private var environment
    @State private var autoUpdate = true
    @State private var lastCheck: Date?

    var body: some View {
        let updater = environment.dictionaryUpdater
        Section {
            Toggle("Keep Recommended Up to Date", isOn: $autoUpdate)
                .onChange(of: autoUpdate) { _, on in updater.autoUpdate = on }
                .accessibilityIdentifier("dictionaries.autoUpdate")
            Button {
                Task {
                    await updater.checkForUpdates()
                    lastCheck = updater.lastCheck
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Check Now")
                        if updater.isChecking { ProgressView().padding(.leading, 4) }
                    }
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
            }
            .disabled(updater.isChecking || updater.isInstalling)
            .accessibilityIdentifier("dictionaries.checkNow")
        } header: {
            Text("Updates")
        } footer: {
            Text("Updates download on Wi-Fi and replace the old version when it's ready. Imported dictionaries don't update unless they say they can.")
        }
        .onAppear {
            autoUpdate = updater.autoUpdate
            lastCheck = updater.lastCheck
        }
        .onChange(of: updater.isInstalling) { lastCheck = updater.lastCheck }
    }

    private var status: String {
        let updater = environment.dictionaryUpdater
        if updater.isChecking { return "Checking…" }
        let checked = lastCheck.map { "Last checked \($0.formatted(.relative(presentation: .named)))" } ?? "Not checked yet"
        return [checked, updater.lastResult].compactMap { $0 }.joined(separator: " · ")
    }
}
