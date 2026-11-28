import SwiftUI

public extension Notification.Name {
    /// View ▸ Refresh (⌘R) on the Mac: the screens showing load again.
    static let refreshRequested = Notification.Name("refreshRequested")
}

public extension View {
    /// Pull to refresh, and View ▸ Refresh (⌘R) on the Mac, which has no pull.
    func refreshableByCommand(_ action: @escaping @MainActor () async -> Void) -> some View {
        refreshable { await action() }
            .onReceive(NotificationCenter.default.publisher(for: .refreshRequested)) { _ in Task { await action() } }
    }
}

/// The Refresh item for the Mac's View menu.
public struct RefreshCommand: View {
    public init() {}

    public var body: some View {
        Button("Refresh") {
            CoverLoader.recheck()
            NotificationCenter.default.post(name: .refreshRequested, object: nil)
        }
        .keyboardShortcut("r", modifiers: .command)
    }
}
