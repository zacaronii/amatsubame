import CoreGraphics

/// Facing pages on a screen folded down the middle: one page each side of
/// the crease, each the size of the folded screen's page so it breaks at the same places, in
/// the reader's coordinates (its safe area's origin).
struct SpreadFrames: Equatable {
    /// The page read first: the right one in right-to-left books.
    var first: CGRect
    var second: CGRect

    /// The folded screen's page for a foldable whose open screen is `screen` (either way round),
    /// before a book has been read folded: the iPhone Duo's outer screen is 466 × 678 with its
    /// status column (84) at the side and a 34 pt bottom inset. A measured one replaces it.
    static func knownFoldedPage(openScreen screen: CGSize) -> CGSize? {
        let sides = [Int(min(screen.width, screen.height).rounded()), Int(max(screen.width, screen.height).rounded())]
        return sides == [669, 951] ? CGSize(width: 382, height: 644) : nil
    }

    /// Room under the pages for the progress text, above the bar at the screen's bottom edge.
    static let bottomRoom: CGFloat = 24

    /// - Parameters:
    ///   - size: the reader's safe area; `insets`: its insets (the pages may reach into them, above
    ///     the progress text).
    ///   - fold: the crease with its margins; only one running top to bottom makes a spread.
    ///   - folded: the folded screen's page (its safe area) when known; otherwise each page fills its half.
    static func make(size: CGSize, insets: (top: CGFloat, leading: CGFloat, bottom: CGFloat, trailing: CGFloat), fold: CGRect,
                     folded: CGSize?, rightToLeft: Bool) -> SpreadFrames? {
        guard fold.height >= fold.width, fold.minX > 0, fold.maxX < size.width else { return nil }
        // Measured on the whole screen, insets and all: the status bar coming and going with the
        // controls (at the top, or in the Duo's side column) changes the safe area, and mustn't
        // move or resize the pages.
        let leftWidth = insets.leading + fold.minX, rightWidth = size.width + insets.trailing - fold.maxX
        let topInset = insets.top
        let height = insets.top + size.height + insets.bottom - bottomRoom
        let half = CGSize(width: min(leftWidth, rightWidth), height: height)
        guard half.width > 200, half.height > 300 else { return nil }
        var page = half
        if let folded, folded.width <= half.width, folded.height <= half.height { page = folded }
        let y = ((height - page.height) / 2).rounded() - topInset
        let left = CGRect(x: ((leftWidth - page.width) / 2).rounded() - insets.leading, y: y, width: page.width, height: page.height)
        let right = CGRect(x: (fold.maxX + (rightWidth - page.width) / 2).rounded(), y: y, width: page.width, height: page.height)
        return rightToLeft ? SpreadFrames(first: right, second: left) : SpreadFrames(first: left, second: right)
    }
}
