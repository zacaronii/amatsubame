import SwiftUI

extension Color {
    /// The app's colour for text: its `TextAccent` asset, the brand colour darkened in light mode
    /// (and lifted in Miru's dark mode) so text in it reads at 4.5:1. Fills, toggles and icons keep
    /// the brand colour (`AccentColor`).
    public static let textAccent = Color("TextAccent")
    /// The fill behind white text (Start Reading, Add Recommended…): the darker shade in both
    /// modes, so the white text reads at 4.5:1.
    public static let filledAccent = Color("FilledAccent")
}

extension View {
    /// A plain text button (Test Connection, See All, Start Reading…) in the app's text colour.
    public func textButtonTint() -> some View {
        tint(.textAccent)
    }

    /// A filled button with white text (`.borderedProminent`) in the app's darker shade.
    public func filledButtonTint() -> some View {
        tint(.filledAccent)
    }
}
