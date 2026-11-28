import SwiftUI

public extension View {
    /// A cover's rounded shape with a hairline edge, so a white or very light cover doesn't blend
    /// into a light background (as Apple Books and Photos draw theirs).
    func coverShape(cornerRadius: CGFloat) -> some View {
        clipShape(.rect(cornerRadius: cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(.primary.opacity(0.12), lineWidth: 0.5)
            }
    }
}
