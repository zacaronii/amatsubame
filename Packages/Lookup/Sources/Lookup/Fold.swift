import SwiftUI

/// The fold of a foldable screen (the iPhone Duo's inner screen), in a view's own coordinates:
/// the region the system reserves for the crease (`reservedRegions(kind: .division)`), with its
/// margins, and how far the hinge is open. Nothing on screens without one.
public struct Fold: Equatable, Sendable {
    /// The crease and its margins: keep text, buttons and popups out of it.
    public var frame: CGRect
    public var hinge: Hinge
    /// The system marks the region inactive while the screen lies flat (fully open, where content
    /// may span it); half open it's active. The crease is there either way.
    public var isActive = true

    public enum Hinge: Equatable, Sendable {
        case unknown, closed, partiallyOpen, fullyOpen
    }

    public init(frame: CGRect, hinge: Hinge = .unknown, isActive: Bool = true) {
        self.frame = frame
        self.hinge = hinge
        self.isActive = isActive
    }

    /// Runs top to bottom, so the screen has a left and a right half (landscape, or a book half open).
    public var isVertical: Bool { frame.height >= frame.width }

    /// Half open like a laptop on a table: the fold runs across.
    public var isTabletop: Bool { !isVertical && hinge == .partiallyOpen }

    /// The parts of `bounds` on either side of the fold: left and right, or top and bottom.
    public func halves(of bounds: CGRect) -> (first: CGRect, second: CGRect) {
        if isVertical {
            return (CGRect(x: bounds.minX, y: bounds.minY, width: max(frame.minX - bounds.minX, 0), height: bounds.height),
                    CGRect(x: frame.maxX, y: bounds.minY, width: max(bounds.maxX - frame.maxX, 0), height: bounds.height))
        }
        return (CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: max(frame.minY - bounds.minY, 0)),
                CGRect(x: bounds.minX, y: frame.maxY, width: bounds.width, height: max(bounds.maxY - frame.maxY, 0)))
    }
}

/// Gives its content the fold crossing it, if any (`Fold`), and keeps it current as the screen
/// folds, unfolds or rotates.
public struct FoldReader<Content: View>: View {
    let content: (Fold?) -> Content
    @State private var hinge = Fold.Hinge.unknown

    public init(@ViewBuilder content: @escaping (Fold?) -> Content) {
        self.content = content
    }

    public var body: some View {
        GeometryReader { geometry in
            content(Self.fold(in: geometry, hinge: hinge))
        }
        .modifier(HingeObserver(hinge: $hinge))
    }

    private static func fold(in geometry: GeometryProxy, hinge: Fold.Hinge) -> Fold? {
        Fold.crossing(geometry, hinge: hinge)
    }
}

extension Fold {
    /// The fold crossing `geometry`'s view, in its coordinates (nil on screens without one).
    @MainActor public static func crossing(_ geometry: GeometryProxy, hinge: Hinge = .unknown) -> Fold? {
        #if os(iOS)
        if #available(iOS 27.1, *) {
            let bounds = CGRect(origin: .zero, size: geometry.size)
            guard let region = geometry.reservedRegions(kind: .division, options: .includeInactive, layoutDirectionBehavior: .fixed)
                .first(where: { $0.frame.intersects(bounds) }) else { return nil }
            return Fold(frame: region.frame, hinge: hinge, isActive: region.isActive)
        }
        #endif
        return nil
    }
}

private struct HingeObserver: ViewModifier {
    @Binding var hinge: Fold.Hinge

    func body(content: Content) -> some View {
        #if os(iOS)
        if #available(iOS 27.1, *) {
            content.onHingeChange { _, context in
                hinge = switch context.hinge?.status {
                case .closed?: .closed
                case .partiallyOpen?: .partiallyOpen
                case .fullyOpen?: .fullyOpen
                default: .unknown
                }
            }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

extension View {
    /// Calls `action` with the hinge's state (now, and as it changes) on a foldable iPhone.
    public func onHingeChange(perform action: @escaping (Fold.Hinge) -> Void) -> some View {
        modifier(HingeAction(action: action))
    }
}

private struct HingeAction: ViewModifier {
    let action: (Fold.Hinge) -> Void
    @State private var hinge = Fold.Hinge.unknown

    func body(content: Content) -> some View {
        content
            .modifier(HingeObserver(hinge: $hinge))
            .onChange(of: hinge, initial: true) { _, hinge in action(hinge) }
    }
}
