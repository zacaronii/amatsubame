import SwiftUI

/// Settings ▸ Lookup: whether words are marked by their state in the mining deck.
public struct WordMarksToggle: View {
    @Environment(CommonEnvironment.self) private var environment

    public init() {}

    /// The Lookup section's footer, saying what the marks mean.
    public static let footer = "Underlines words you haven\u{2019}t mined, and words you\u{2019}re still learning. Known words stay plain."

    public var body: some View {
        let mining = environment.mining
        Toggle("Mark Words by Anki State", systemImage: "underline", isOn: Binding {
            _ = mining.revision // redraw when the setting changes
            return mining.marksWords
        } set: {
            mining.setMarksWords($0)
        })
        .accessibilityIdentifier("lookup.marksWords")
    }
}
