import SwiftUI

#if os(iOS)
/// Settings ▸ Listening ▸ Apple Watch: Kiku on the watch in one place: Live Text, the rules for
/// what goes to the watch, and what's on it now.
struct AppleWatchSettingsView: View {
    @Environment(KikuEnvironment.self) private var environment

    var body: some View {
        Form {
            // The rules and the list show once the watch has Kiku; say why they're missing.
            if !environment.watchLibrary.isWatchAppInstalled {
                Section {
                    Label("Kiku isn\u{2019}t on your Apple Watch yet. Install it from the Watch app; the rest of these settings show once it\u{2019}s there.",
                          systemImage: "applewatch.slash")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("appleWatch.notInstalled")
                }
            }
            KikuSettingsView.WatchLiveTextSection()
            WatchRulesSection()
            OnWatchSection()
        }
        .formStyle(.grouped)
        .navigationTitle("Apple Watch")
    }
}
#endif
