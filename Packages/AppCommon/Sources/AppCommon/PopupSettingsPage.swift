import Core
import Lookup
import SwiftUI

/// Settings ▸ Lookup and Mining ▸ Popup: how the lookup popup looks and what it keeps,
/// following Hachidori's own settings and wording.
public struct PopupSettingsPage: View {
    @Environment(CommonEnvironment.self) private var environment
    @State private var confirmsReset = false
    @State private var resetDone = false
    @State private var dictionaries: [DictionaryRecord] = []

    public init() {}

    /// Hachidori is on: its settings apply, and are kept for when it's away.
    private var followsHachidori: Bool { environment.hachidori != nil }

    public var body: some View {
        let lookup = environment.lookup
        // The sections are disabled, not the Form: a disabled Form doesn't scroll on iOS.
        Form {
            if followsHachidori {
                Section {
                    Label("These follow your Hachidori host, also while it can't be reached. Change them in Hachidori.", systemImage: "bird")
                        .accessibilityIdentifier("popup.followsHachidori")
                }
            }
            Section {
                Toggle("Show Brief Definitions Beside the Headword", isOn: setting(\.showCompactDefinitionSummary))
                    .accessibilityIdentifier("popup.compactSummary")
                if lookup.popupSettings.showCompactDefinitionSummary {
                    Picker("Snippets", selection: setting(\.compactDefinitionSummaryCount)) {
                        ForEach(CompactDefinitionSummary.counts, id: \.self) { count in
                            Text(count == 1 ? "1 snippet" : "\(count) snippets").tag(count)
                        }
                    }
                    Picker("Summary Dictionary", selection: setting(\.compactDefinitionSummaryDictionary)) {
                        Text("Automatic").tag(String?.none)
                        ForEach(dictionaries.filter(\.hasTerms), id: \.id) { dictionary in
                            Text(dictionary.title).tag(String?.some(dictionary.title))
                        }
                    }
                }
            } header: {
                Text("First Meaning")
            } footer: {
                Text("Full definitions stay available below. Without a summary dictionary, the first dictionary with a definition is used.")
            }
            .disabled(followsHachidori)
            Section {
                LabeledContent("Background Opacity") {
                    HStack {
                        Slider(value: Binding { Double(lookup.popupSettings.backgroundOpacityPercent) } set: { value in
                            lookup.updatePopupSettings { $0.backgroundOpacityPercent = Int(value.rounded()) }
                        }, in: 0...100, step: 1)
                        .frame(minWidth: 120)
                        .accessibilityIdentifier("popup.backgroundOpacity")
                        Text("\(lookup.popupSettings.backgroundOpacityPercent) %").monospacedDigit().frame(minWidth: 48, alignment: .trailing)
                    }
                }
            } header: {
                Text("Appearance")
            } footer: {
                Text("What shows through is always blurred, and text stays solid; at low opacity it gets a soft halo so it stays readable.")
            }
            .disabled(followsHachidori)
            #if os(macOS)
            // The Mac's own (not one of Hachidori's options), so it stays changeable.
            Section {
                Picker("Look Up on Hover", selection: setting(\.hoverLookup)) {
                    Text("Off").tag(PopupSettings.HoverLookup.off)
                    Divider()
                    Text("Holding Shift ⇧").tag(PopupSettings.HoverLookup.shift)
                    Text("Holding Option ⌥").tag(PopupSettings.HoverLookup.option)
                    Text("Holding Control ⌃").tag(PopupSettings.HoverLookup.control)
                    Text("Holding Command ⌘").tag(PopupSettings.HoverLookup.command)
                    Divider()
                    Text("Without a Key").tag(PopupSettings.HoverLookup.always)
                }
                .accessibilityIdentifier("popup.hoverLookup")
            } header: {
                Text("Pointer")
            } footer: {
                Text("Point at a word in a book in Yomu, Miru\u{2019}s subtitles or Kiku\u{2019}s transcript to look it up without clicking: while holding the key, or just by resting on it. Clicking a word always works. Manga pages still need a click.")
            }
            #endif
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
            .disabled(followsHachidori)
        }
        .formStyle(.grouped)
        .navigationTitle("Popup")
        .task {
            do {
                for try await records in environment.dictionaries.observeDictionaries() { dictionaries = records }
            } catch {}
        }
        .confirmationDialog("Reset Lookup Counts?", isPresented: $confirmsReset, titleVisibility: .visible) {
            Button("Reset Lookup Counts", role: .destructive) {
                try? lookup.counts.reset()
                resetDone = true
            }
        } message: {
            Text("Every word starts again from zero; your next lookup of it counts as 1. Dictionaries, settings and Anki notes are not changed.")
        }
    }

    private func setting<Value>(_ keyPath: WritableKeyPath<PopupSettings, Value>) -> Binding<Value> {
        let lookup = environment.lookup
        return Binding { lookup.popupSettings[keyPath: keyPath] } set: { value in lookup.updatePopupSettings { $0[keyPath: keyPath] = value } }
    }
}
