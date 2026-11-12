import SwiftUI

/// Settings ▸ Lookup: whether words are marked by their state in the mining deck.
public struct WordMarksToggle: View {
    @Environment(CommonEnvironment.self) private var environment

    public init() {}

    /// The Lookup section's footer, saying what the marks mean.
    public static let footer = "Underlines words you haven\u{2019}t mined, and words you\u{2019}re still learning. Known words stay plain."

    public var body: some View {
        let mining = environment.mining
        Toggle(isOn: Binding {
            _ = mining.revision // redraw when the setting changes
            return mining.marksWords
        } set: {
            mining.setMarksWords($0)
        }) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Mark Words by Anki State")
                    if !mining.ankiConnected {
                        Text("Connect Anki to mark words").font(.caption).foregroundStyle(.secondary)
                    }
                }
            } icon: {
                Image(systemName: "underline")
            }
        }
        // Off until Anki is connected: with no mined words, every word would be marked.
        .disabled(!mining.ankiConnected)
        .accessibilityIdentifier("lookup.marksWords")
    }
}
