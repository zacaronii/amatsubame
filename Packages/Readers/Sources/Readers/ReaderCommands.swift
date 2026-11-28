import Lookup
import SwiftUI

extension View {
    /// The lookup over a reader: a card by the tapped word, or a bottom panel on a phone
    /// (`lookupOverlay`). Nothing until the reader has a lookup service.
    @ViewBuilder func readerLookupOverlay<Panel: View>(
        _ popup: LookupPopupModel?, lookup: LookupService?, anchor: CGRect, in space: LookupAnchorSpace = .local, beside: Bool,
        onClose: @escaping () -> Void, @ViewBuilder panel: @escaping (LookupPopupModel, LookupService) -> Panel
    ) -> some View {
        if let lookup {
            lookupOverlay(popup, service: lookup, anchor: anchor == .zero ? nil : anchor, in: space, beside: beside, onClose: onClose) { panel($0, lookup) }
        } else {
            self
        }
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
    /// Opens Search in the book that's open (the Reader menu gives it ⌘F then).
    @Entry public var bookSearch: (() -> Void)?
}
