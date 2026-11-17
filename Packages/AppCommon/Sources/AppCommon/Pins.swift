import Core
import SwiftUI

/// What's pinned to the Mac's sidebar (series, shows, movies, books), oldest first.
@Observable
public final class Pins {
    public private(set) var items: [PinnedItem] = []
    @ObservationIgnored private let store: PinStore

    init(store: PinStore) {
        self.store = store
        items = (try? store.all()) ?? []
    }

    public func isPinned(_ id: String) -> Bool {
        items.contains { $0.id == id }
    }

    public func pin(id: String, kind: String, title: String) {
        try? store.pin(PinnedItem(id: id, kind: kind, title: title))
        items = (try? store.all()) ?? items
    }

    public func unpin(_ id: String) {
        try? store.unpin(id: id)
        items.removeAll { $0.id == id }
    }
}

#if os(macOS)
public extension View {
    /// A Pin button in the toolbar of a series, show, movie or book page (Mac): it adds the page
    /// to the sidebar's Pinned section, or takes it out.
    func pinnable(id: String, kind: String, title: String) -> some View {
        modifier(PinToolbarButton(id: id, kind: kind, title: title))
    }
}

private struct PinToolbarButton: ViewModifier {
    @Environment(CommonEnvironment.self) private var common
    let id: String
    let kind: String
    let title: String

    func body(content: Content) -> some View {
        content.toolbar {
            ToolbarItem(placement: .primaryAction) {
                let pinned = common.pins.isPinned(id)
                Button(pinned ? "Unpin" : "Pin", systemImage: pinned ? "pin.slash" : "pin") {
                    if pinned { common.pins.unpin(id) } else { common.pins.pin(id: id, kind: kind, title: title) }
                }
                // Not before the page knows its title (the sidebar shows it).
                .disabled(!pinned && title.isEmpty)
                .help(pinned ? "Remove from the sidebar" : "Pin to the sidebar")
                .accessibilityIdentifier("page.pin")
            }
        }
    }
}
#endif
