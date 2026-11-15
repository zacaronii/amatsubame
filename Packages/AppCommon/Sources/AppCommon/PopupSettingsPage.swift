import SwiftUI

/// Settings ▸ Lookup and Mining ▸ Popup: how the lookup popup looks and what it keeps,
/// following Hachidori's own settings and wording.
public struct PopupSettingsPage: View {
    @Environment(CommonEnvironment.self) private var environment
    @State private var confirmsReset = false
    @State private var resetDone = false

    public init() {}

    public var body: some View {
        let lookup = environment.lookup
        Form {
            Section {
                Toggle("Record and Show Lookup Counts", isOn: Binding { lookup.showsLookupCounts } set: { lookup.setShowsLookupCounts($0) })
                    .accessibilityIdentifier("popup.lookupCounts")
                Button("Reset Lookup Counts", role: .destructive) { confirmsReset = true }
                    .accessibilityIdentifier("popup.resetLookupCounts")
            } header: {
                Text("Lookup History")
            } footer: {
                Text(resetDone ? "Lookup counts were reset."
                     : "See how often you look up a word. Turning this off keeps your past counts. Counts are shared by the apps that share this setup.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Popup")
        .confirmationDialog("Reset Lookup Counts?", isPresented: $confirmsReset, titleVisibility: .visible) {
            Button("Reset Lookup Counts", role: .destructive) {
                try? lookup.counts.reset()
                resetDone = true
            }
        } message: {
            Text("Every word starts again from zero; your next lookup of it counts as 1. Dictionaries, settings and Anki notes are not changed.")
        }
    }
}
