import SwiftUI

#if os(iOS)
/// Settings ▸ Listening ▸ Apple Watch: Kiku on the watch in one place: Live Text, the rules for
/// what goes to the watch, and what's on it now.
struct AppleWatchSettingsView: View {
    var body: some View {
        Form {
            KikuSettingsView.WatchLiveTextSection()
            WatchRulesSection()
            OnWatchSection()
        }
        .formStyle(.grouped)
        .navigationTitle("Apple Watch")
    }
}
#endif
