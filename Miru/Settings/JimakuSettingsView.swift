import AppCommon
import Core
import JimakuKit
import SwiftUI

/// Settings → Jimaku: the API key for finding Japanese subtitles (kept in the Keychain).
struct JimakuSettingsView: View {
    @Environment(PlayerEnvironment.self) private var environment
    @State private var key = ""
    @State private var hasKey = false
    @State private var status: String?
    @State private var isTesting = false

    var body: some View {
        Form {
            Section {
                SecureField("API Key", text: $key)
                    .textContentType(.password)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .accessibilityIdentifier("jimaku.key")
                Button("Save and Test") { Task { await saveAndTest() } }
                    .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty || isTesting)
                    .accessibilityIdentifier("jimaku.save")
                if let status {
                    Text(status).font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("jimaku.status")
                }
            } footer: {
                Text("Jimaku has Japanese subtitles for most anime. Make a free account at jimaku.cc, then create a key on its Account page. The player's Find Subtitles button searches there.")
            }
            if hasKey {
                Section {
                    Button("Remove Key", role: .destructive) {
                        try? environment.common.secrets.setSecret(nil, for: .jimakuAPIKey)
                        key = ""
                        hasKey = false
                        status = nil
                    }
                }
            }
        }
        .navigationTitle("Jimaku")
        .onAppear {
            let saved = (try? environment.common.secrets.secret(for: .jimakuAPIKey)) ?? nil
            hasKey = saved != nil
            key = saved ?? ""
        }
    }

    private func saveAndTest() async {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try environment.common.secrets.setSecret(trimmed, for: .jimakuAPIKey)
        } catch {
            status = "Couldn't save the key: \(error.localizedDescription)"
            return
        }
        hasKey = true
        isTesting = true
        defer { isTesting = false }
        status = "Testing…"
        do {
            _ = try await environment.jimakuClient()?.search(query: "テスト")
            status = "Saved. Jimaku accepted the key."
        } catch .unauthorized {
            status = "Saved, but Jimaku didn't accept the key. Check it on jimaku.cc → Account."
        } catch {
            status = "Saved. Couldn't reach Jimaku to check it: \(error.localizedDescription)"
        }
    }
}

/// The Settings row: Jimaku and whether a key is set.
struct JimakuRow: View {
    @Environment(PlayerEnvironment.self) private var environment
    @State private var hasKey = false

    var body: some View {
        LabeledContent {
            Text(hasKey ? "Key set" : "Not set up")
        } label: {
            Label("Jimaku", systemImage: "captions.bubble")
        }
        .onAppear { hasKey = ((try? environment.common.secrets.secret(for: .jimakuAPIKey)) ?? nil) != nil }
    }
}
