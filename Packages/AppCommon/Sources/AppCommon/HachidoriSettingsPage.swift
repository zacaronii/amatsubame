import Core
import HachidoriKit
import Lookup
import SwiftUI

/// Settings ▸ Lookup and Mining ▸ Hachidori: look words up on a Hachidori host (docs/hachidori.md).
/// On the Mac the apps link to the host like a linked browser; shared with the other apps.
public struct HachidoriSettingsPage: View {
    @Environment(CommonEnvironment.self) private var environment
    @State private var enabled = false
    @State private var address = ""
    @State private var loaded = false

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
                    .onSubmit(save)
                    .accessibilityIdentifier("hachidori.address")
                if addressChanged {
                    Button("Link", action: save)
                        .disabled(HachidoriLink.linkURL(from: address) == nil)
                        .accessibilityIdentifier("hachidori.link")
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
                    if let host = environment.lookup.host, host.isLinked {
                        LabeledContent("Dictionaries", value: host.dictionaries.filter(\.enabled).map(\.name).joined(separator: ", "))
                    }
                }
                Section {
                    Label("Words are looked up on Hachidori, with its dictionaries.", systemImage: "character.book.closed.ja")
                    Label("Lookup counts are Hachidori's, shared with your browser.", systemImage: "number")
                    Label("The popup follows Hachidori's settings (first meaning, lookup counts, opacity).", systemImage: "text.bubble")
                    Label("Words marked known or ignored in Hachidori get no word mark.", systemImage: "checkmark.circle")
                } header: {
                    Text("While Linked")
                } footer: {
                    Text("When Hachidori can't be reached, lookups use this Mac's own dictionaries and counts. Cards still go to your Anki through this app's own settings.")
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

    private var addressChanged: Bool {
        address.trimmingCharacters(in: .whitespacesAndNewlines) != environment.hachidoriSettings.address
    }

    private func save() {
        environment.saveHachidoriSettings(HachidoriSettings(enabled: enabled, address: address.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    private var statusText: String {
        guard let host = environment.lookup.host else {
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
        switch environment.lookup.host?.status {
        case .linked: .green
        case .waiting: .orange
        default: .secondary
        }
    }

    /// The row's subtitle in Settings.
    static func summary(_ environment: CommonEnvironment) -> String {
        guard environment.hachidoriSettings.enabled else { return "Off" }
        switch environment.lookup.host?.status {
        case .linked: return "Linked"
        case .waiting: return "Not reachable"
        default: return "Connecting"
        }
    }
}
