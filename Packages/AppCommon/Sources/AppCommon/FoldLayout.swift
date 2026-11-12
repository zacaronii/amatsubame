import Lookup
import SwiftUI

extension View {
    /// A horizontal shelf scrolls out past its padding to the screen edge, but stops at the side
    /// safe area: on the iPhone Duo's outer screen that's the clock and status column.
    /// `outset` is the padding around the shelf (`.padding()`).
    public func shelfScrollClip(outset: CGFloat = 16) -> some View {
        #if os(iOS)
        scrollClipDisabled()
            .mask { Rectangle().padding(.horizontal, -outset).padding(.vertical, -400) }
        #else
        scrollClipDisabled()
        #endif
    }
}

extension View {
    /// With the tab bar in a column at the side (the iPhone Duo), a tab bar accessory (Kiku's
    /// mini player) floats over the bottom of the screen: nothing is drawn under it while it
    /// shows. The system already leaves room for it at the end of a list.
    public func clearOfBottomAccessory(_ shown: Bool) -> some View {
        modifier(ClearOfBottomAccessory(shown: shown))
    }
}

private struct ClearOfBottomAccessory: ViewModifier {
    let shown: Bool
    @State private var insets = EdgeInsets()

    func body(content: Content) -> some View {
        // A bottom tab bar leaves a tall bottom inset; a side one a wide side inset instead.
        let sideTabBar = max(insets.leading, insets.trailing) > 44
        content
            .mask {
                VStack(spacing: 0) {
                    Rectangle()
                    // A little above the mini player too, so no line is cut right at its edge.
                    Color.clear.frame(height: shown && sideTabBar ? insets.bottom + 8 : 0)
                }
                .ignoresSafeArea()
            }
            .onGeometryChange(for: EdgeInsets.self) { $0.safeAreaInsets } action: { insets = $0 }
    }
}

extension EnvironmentValues {
    /// The first screen of a `WideSplitStack` on a wide screen: what it opens shows beside it.
    @Entry public var isWideSplit = false
}

/// Where a wide screen splits into two columns: at the fold, with the
/// crease between them, or, on a wide screen without one (an iPad sideways), a little left of
/// the middle. Nil when the screen isn't wide enough for two.
public struct WideColumns: Equatable, Sendable {
    public var left: CGFloat
    public var gap: CGFloat
    public var right: CGFloat

    public static func make(size: CGSize, fold: Fold?) -> WideColumns? {
        if let fold, fold.isVertical, fold.frame.minX > 200, size.width - fold.frame.maxX > 200 {
            return WideColumns(left: fold.frame.minX, gap: fold.frame.width, right: size.width - fold.frame.maxX)
        }
        guard size.width >= 700, size.width > size.height else { return nil }
        let left = (size.width * 0.42).rounded()
        return WideColumns(left: left, gap: 0, right: size.width - left)
    }

    #if os(iOS)
    @MainActor public static func make(_ geometry: GeometryProxy) -> WideColumns? {
        make(size: geometry.size, fold: Fold.crossing(geometry))
    }
    #else
    @MainActor public static func make(_ geometry: GeometryProxy) -> WideColumns? { nil }
    #endif
}

/// A navigation stack that, on a wide screen, keeps its first screen on the left and shows what
/// it opens on the right (where deeper screens stack in turn). Otherwise an ordinary stack.
/// Links on the first screen must open `Route` values.
public struct WideSplitStack<Route: Hashable, Root: View, Destination: View, Empty: View>: View {
    @Binding var path: [Route]
    /// A back button on the right side, to how it started (the empty state). Without it a pick
    /// on the left just replaces the right side.
    let showsBack: Bool
    let root: () -> Root
    let destination: (Route) -> Destination
    let empty: () -> Empty

    public init(path: Binding<[Route]>, showsBack: Bool = true, @ViewBuilder root: @escaping () -> Root,
                @ViewBuilder destination: @escaping (Route) -> Destination, @ViewBuilder empty: @escaping () -> Empty) {
        _path = path
        self.showsBack = showsBack
        self.root = root
        self.destination = destination
        self.empty = empty
    }

    public var body: some View {
        GeometryReader { geometry in
            if let columns = WideColumns.make(geometry) {
                HStack(spacing: 0) {
                    // A link tapped here lands on the right: the left stack never moves.
                    NavigationStack(path: Binding(get: { [Route]() }, set: { opened in
                        if let route = opened.last { path = [route] }
                    })) {
                        root()
                            // It never reaches the screen's far side, but its navigation stack
                            // takes that side's safe area (the Duo's status column) as its own,
                            // and the screen drew short of it.
                            .ignoresSafeArea(.container, edges: .trailing)
                            .navigationDestination(for: Route.self) { destination($0) }
                            .environment(\.isWideSplit, true)
                    }
                    .frame(width: columns.left)
                    Color.clear.frame(width: columns.gap)
                    NavigationStack(path: Binding(get: { Array(path.dropFirst()) }, set: { tail in
                        // Opened from the empty state: that becomes the right side's screen.
                        path = path.first.map { [$0] + tail } ?? tail
                    })) {
                        Group {
                            if let first = path.first {
                                destination(first)
                                    .toolbar {
                                        // Back to how the right side started.
                                        if showsBack {
                                            ToolbarItem(placement: .navigation) {
                                                Button("Back", systemImage: "chevron.backward") { path = [] }
                                                    .accessibilityIdentifier("split.back")
                                            }
                                        }
                                    }
                            } else {
                                empty()
                            }
                        }
                        .navigationDestination(for: Route.self) { destination($0) }
                    }
                    .id(path.first)
                    .frame(width: columns.right)
                }
            } else {
                NavigationStack(path: $path) {
                    root().navigationDestination(for: Route.self) { destination($0) }
                }
                .onAppear {
                    // Folded with something open on the right: a stack made with it already open
                    // showed it without a back button. Start from the first screen and open it again.
                    guard !path.isEmpty else { return }
                    let open = path
                    path = []
                    Task { @MainActor in
                        await Task.yield()
                        path = open
                    }
                }
            }
        }
    }
}

/// Reads `isWideSplit` where it's set (inside the split), for the screen building it.
public struct WideSplitReader<Content: View>: View {
    @Environment(\.isWideSplit) private var isWideSplit
    let content: (Bool) -> Content

    public init(@ViewBuilder content: @escaping (Bool) -> Content) {
        self.content = content
    }

    public var body: some View { content(isWideSplit) }
}
