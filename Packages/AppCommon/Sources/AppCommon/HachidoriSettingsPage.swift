import Core
import HachidoriKit
import Lookup
import SwiftUI

/// Settings ▸ Lookup and Mining ▸ Hachidori: link to a Hachidori host like a linked browser
/// (docs/hachidori.md); shared with the other apps. The Mac apps look words up on it; on every
/// platform its dictionaries can be copied, and yours sent to it (Settings ▸ Dictionaries).
public struct HachidoriSettingsPage: View {
    @Environment(CommonEnvironment.self) private var environment
    @State private var enabled = false
    @State private var address = ""
    @State private var loaded = false
    @State private var test: TestResult?

    enum TestResult {
        case testing
        case found(HostHello)
        case failed
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
                        .disabled(HachidoriLink.linkURL(from: address) == nil)
                        .accessibilityIdentifier("hachidori.link")
                }
                Button("Test Connection", action: runTest)
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
                    #if os(macOS)
                    Label("Words are looked up on Hachidori, with its dictionaries.", systemImage: "character.book.closed.ja")
                    Label("Lookup counts are Hachidori's, shared with your browser.", systemImage: "number")
                    Label("The popup follows Hachidori's settings (first meaning, lookup counts, opacity).", systemImage: "text.bubble")
                    Label("Words marked known or ignored in Hachidori get no word mark.", systemImage: "checkmark.circle")
                    #endif
                    Label("Copy Hachidori's dictionaries, or send yours to it, in Settings ▸ Dictionaries.", systemImage: "arrow.down.circle")
                } header: {
                    Text("While Linked")
                } footer: {
                    #if os(macOS)
                    Text("When Hachidori can't be reached, lookups use this Mac's own dictionaries and counts. Cards still go to your Anki through this app's own settings.")
                    #else
                    Text("Words are still looked up with this device's own dictionaries, so lookups stay fast and work anywhere.")
                    #endif
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Hachidori")
        .onAppear {
            let settings = environment.hachidoriSettings
            enabled = settings.enabled
            address = settings.address
            loaded = true
        }
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
                test = .failed
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
        case .failed:
            Label("No answer from Hachidori at this address. Check that it's running and that this device can reach it (the same network, or Tailscale).",
                  systemImage: "xmark.circle.fill")
                .foregroundStyle(.orange)
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
