import SwiftUI

/// Where a lookup popup opens beside the tapped text: away from the nearer edge, so it stays
/// inside the window (the arrow sits on the popup's edge facing the text).
public enum PopupPlacement {
    public static func arrowEdge(for anchor: CGRect, width: CGFloat) -> Edge {
        guard width > 0 else { return .leading }
        // Text in the right half: the popup opens to its left (arrow on the popup's trailing edge).
        return anchor.midX > width / 2 ? .trailing : .leading
    }
}

/// Page turning the frontmost reader offers to menus (Mac menu bar).
public struct ReaderPaging {
    public let next: () -> Void
    public let previous: () -> Void

    public init(next: @escaping () -> Void, previous: @escaping () -> Void) {
        self.next = next
        self.previous = previous
    }
}

extension FocusedValues {
    @Entry public var readerPaging: ReaderPaging?
}
