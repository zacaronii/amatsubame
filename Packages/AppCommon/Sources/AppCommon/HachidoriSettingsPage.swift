import Core
import HachidoriKit
import Lookup
import SwiftUI

/// Settings ▸ Connections ▸ Hachidori: link to a Hachidori host like a linked browser
/// (docs/hachidori.md); shared with the other apps. The Mac apps look words up on it; on every
/// platform its dictionaries can be copied, and yours sent to it (Settings ▸ Dictionaries).
public struct HachidoriSettingsPage: View {
    @Environment(CommonEnvironment.self) private var environment
    @State private var enabled = false
    @State private var address = ""
    @State private var loaded = false
    @State private var test: TestResult?
    @State private var waiting = 0
    @State private var waitingMarks = 0

    enum TestResult {
        case testing
        case found(HostHello)
        case failed(String?)
    }

    public init() {}

    public var body: some View {
        Form {
            Section {
                Toggle("Use Hachidori", isOn: $enabled)
                    .accessibilityIdentifier("hachidori.enabled")
                    .onChange(of: enabled) { if loaded { save() } }
                TextField("Address", text: $address, prompt: Text("192.168.1.20 or a Tailscale name"))
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    #endif
                    .onSubmit(save)
                    .onChange(of: address) { test = nil }
                    .accessibilityIdentifier("hachidori.address")
                if addressChanged {
                    Button("Link", action: save)
                        .textButtonTint()
                        .disabled(HachidoriLink.linkURL(from: address) == nil)
                        .accessibilityIdentifier("hachidori.link")
                }
                Button("Test Connection", action: runTest)
                    .textButtonTint()
                    .disabled(HachidoriLink.linkURL(from: address) == nil || isTesting)
                    .accessibilityIdentifier("hachidori.test")
                if let test {
                    testRow(test)
                }
            } footer: {
                Text("The address of the computer running Hachidori, or of its Docker host (port 8771 unless you changed it). Hachidori has no password, so only use it over your home network or a private network such as Tailscale.")
            }
            if enabled {
                Section("Status") {
                    LabeledContent("Link") {
                        Text(statusText).foregroundStyle(statusColor)
                    }
                    .accessibilityIdentifier("hachidori.status")
                    if let host = environment.hachidori, host.isLinked {
                        if let hello = host.hello {
                            LabeledContent("Host", value: hello.name)
                            LabeledContent("Version", value: hello.version)
                        }
                        LabeledContent("Dictionaries", value: host.dictionaries.filter(\.enabled).map(\.name).joined(separator: ", "))
                    }
                }
                Section {
                    LabeledContent("Last Synced") {
                        if let synced = environment.hachidori?.lastSynced {
                            Text(synced, format: .relative(presentation: .named))
                        } else {
                            Text("Not yet")
                        }
                    }
                    LabeledContent("Waiting to Send", value: waitingText)
                        .accessibilityIdentifier("hachidori.waiting")
                } header: {
                    Text("Sync")
                } footer: {
                    #if os(macOS)
                    Text("Lookups and words marked while Hachidori can't be reached go to it once it's back.")
                    #else
                    Text("The app links to Hachidori when it opens or comes back to the front. Lookups and words marked while Hachidori can't be reached go to it once it's back (the lookups at that time).")
                    #endif
                }
                Section {
                    #if os(macOS)
                    Label("Words are looked up on Hachidori, with its dictionaries.", systemImage: "character.book.closed.ja")
                    #endif
                    Label("Lookup counts are Hachidori's, shared with your browser.", systemImage: "number")
                    Label("The popup follows Hachidori's settings (first meaning, lookup counts, opacity), and keeps them when it can't be reached.", systemImage: "text.bubble")
                    Label("Words marked known or ignored, here or in Hachidori, are one list (Settings ▸ Anki ▸ Known and Ignored Words).", systemImage: "checkmark.circle")
                    Label("Copy Hachidori's dictionaries, or send yours to it, in Settings ▸ Dictionaries.", systemImage: "arrow.down.circle")
                } header: {
                    Text("While Linked")
                } footer: {
                    #if os(macOS)
                    Text("When Hachidori can't be reached, lookups use this Mac's own dictionaries and counts. Cards still go to your Anki through this app's own settings.")
                    #else
                    Text("Words are still looked up with this device's own dictionaries, so lookups stay fast and work anywhere. Cards still go to your Anki through this app's own settings.")
                    #endif
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Hachidori")
        .task {
            do {
                for try await counts in environment.outbox.observeWaitingCounts() {
                    waiting = counts[.hachidoriLookupCount] ?? 0
                    waitingMarks = counts[.hachidoriWordStatus] ?? 0
                }
            } catch {}
        }
        .onAppear {
            let settings = environment.hachidoriSettings
            enabled = settings.enabled
            address = settings.address
            loaded = true
        }
    }

    private var waitingText: String {
        let parts = [waiting == 0 ? nil : "\(waiting) \(waiting == 1 ? "word's lookups" : "words' lookups")",
                     waitingMarks == 0 ? nil : "\(waitingMarks) \(waitingMarks == 1 ? "known or ignored word" : "known or ignored words")"]
            .compactMap { $0 }
        return parts.isEmpty ? "Nothing" : parts.formatted(.list(type: .and))
    }

    private var isTesting: Bool {
        if case .testing = test { true } else { false }
    }

    private func runTest() {
        test = .testing
        let address = address
        Task {
            do {
                test = .found(try await environment.testHachidori(address: address))
            } catch {
                test = .failed((error as? HachidoriError).flatMap(\.errorDescription))
            }
        }
    }

    @ViewBuilder
    private func testRow(_ result: TestResult) -> some View {
        switch result {
        case .testing:
            HStack {
                ProgressView().controlSize(.small)
                Text("Testing…").foregroundStyle(.secondary)
            }
        case .found(let hello):
            Label("Found \(hello.name) (\(hello.version)) with \(hello.dictionaryCount) \(hello.dictionaryCount == 1 ? "dictionary" : "dictionaries").",
                  systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityIdentifier("hachidori.testResult")
        case .failed(let reason):
            VStack(alignment: .leading, spacing: 4) {
                Label("No answer from Hachidori at this address. Check that it's running and that this device can reach it (the same network, or Tailscale).",
                      systemImage: "xmark.circle.fill")
                    .foregroundStyle(.orange)
                // What went wrong, as far as this device can tell.
                if let reason { Text(reason).font(.footnote).foregroundStyle(.secondary) }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("hachidori.testResult")
        }
    }

    private var addressChanged: Bool {
        address.trimmingCharacters(in: .whitespacesAndNewlines) != environment.hachidoriSettings.address
    }

    private func save() {
        environment.saveHachidoriSettings(HachidoriSettings(enabled: enabled, address: address.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    private var statusText: String {
        guard let host = environment.hachidori else {
            return HachidoriLink.linkURL(from: address) == nil ? "Enter an address" : "Not linked"
        }
        switch host.status {
        case .stopped: return "Not linked"
        case .connecting: return "Connecting…"
        case .waiting: return "Can't reach Hachidori; trying again"
        case .linked(let name, let version, _): return "Linked to \(name) (\(version))"
        }
    }

    private var statusColor: Color {
        switch environment.hachidori?.status {
        case .linked: .green
        case .waiting: .orange
        default: .secondary
        }
    }

    /// The row's subtitle in Settings.
    static func summary(_ environment: CommonEnvironment) -> String {
        guard environment.hachidoriSettings.enabled else { return "Off" }
        switch environment.hachidori?.status {
        case .linked: return "Linked"
        case .waiting: return "Not reachable"
        default: return "Connecting"
        }
    }
}
