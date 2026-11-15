import SwiftUI

/// Where a popup's anchor rect is measured: in the view the overlay is attached to, or in the
/// window (`.global`, what a tap's location gives).
public enum LookupAnchorSpace: Sendable {
    case local, global
}

/// Where the popup goes (pure, so it can be tested): like Hachidori's, a card by the word on a
/// wide screen, and a panel along the bottom on a narrow one.
public enum LookupOverlayPlacement {
    /// Narrower than this, the popup is a bottom panel (an iPhone held upright).
    public static let bottomPanelWidth: CGFloat = 600
    public static let cardSize = CGSize(width: 420, height: 460)
    /// The shortest card worth showing; with less room on both sides it covers the word.
    static let minimumCardHeight: CGFloat = 220
    static let gap: CGFloat = 8
    static let margin: CGFloat = 12

    public static func usesBottomPanel(_ size: CGSize) -> Bool {
        size.width < bottomPanelWidth
    }

    /// The card's frame in `bounds`: below the word when it fits, else above it, else on the
    /// roomier side (shorter); centred on the word and kept inside. No word: along the bottom.
    /// `beside` (vertical text, manga): left or right of the word instead, away from the nearer
    /// edge, so the column it's in stays visible.
    public static func cardFrame(anchor: CGRect?, in bounds: CGRect, size: CGSize = cardSize, beside: Bool = false) -> CGRect {
        let inner = bounds.insetBy(dx: margin, dy: margin)
        let width = min(size.width, inner.width)
        if beside, let anchor, !anchor.isNull {
            let height = min(size.height, inner.height)
            let y = min(max(anchor.midY - height / 2, inner.minY), inner.maxY - height)
            let left = (anchor.minX - gap) - inner.minX, right = inner.maxX - (anchor.maxX + gap)
            let sideWidth = min(size.width, max(left, right))
            if sideWidth >= 260 {
                let x = left >= right ? anchor.minX - gap - sideWidth : anchor.maxX + gap
                return CGRect(x: x, y: y, width: sideWidth, height: height)
            }
        }
        guard let anchor, !anchor.isNull else {
            let height = min(size.height, inner.height)
            return CGRect(x: inner.midX - width / 2, y: inner.maxY - height, width: width, height: height)
        }
        let x = min(max(anchor.midX - width / 2, inner.minX), inner.maxX - width)
        let below = inner.maxY - (anchor.maxY + gap)
        let above = (anchor.minY - gap) - inner.minY
        let y: CGFloat, height: CGFloat
        if below >= size.height {
            (y, height) = (anchor.maxY + gap, size.height)
        } else if above >= size.height {
            (y, height) = (anchor.minY - gap - size.height, size.height)
        } else if max(below, above) >= minimumCardHeight {
            height = max(below, above)
            y = below >= above ? anchor.maxY + gap : anchor.minY - gap - height
        } else {
            height = min(size.height, inner.height)
            y = below >= above ? inner.maxY - height : inner.minY
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

public extension View {
    /// Shows `popup` over this view without covering it with a sheet: a card by the word
    /// (`anchor`) on a wide screen, a bottom panel with a handle on a narrow one. What's
    /// behind shows through, lightly blurred, at the popup's opacity, with no dimming, and stays
    /// usable: tapping another word looks it up in place of this one. Taps that miss a word close
    /// the popup where the view handles them (`closeLookup` in the environment); Esc closes it too. `panel` is the popup's content, drawn without a
    /// background (`LookupPopupView(…, drawsBackground: false)`).
    /// `beside`: the card goes left or right of the word (vertical text and manga).
    func lookupOverlay<Panel: View>(_ popup: LookupPopupModel?, service: LookupService, anchor: CGRect? = nil,
                                    in space: LookupAnchorSpace = .global, beside: Bool = false, onClose: @escaping () -> Void,
                                    @ViewBuilder panel: @escaping (LookupPopupModel) -> Panel) -> some View {
        modifier(LookupOverlayModifier(popup: popup, service: service, anchor: anchor, space: space, beside: beside,
                                       onClose: onClose, panel: panel))
    }
}

struct LookupOverlayModifier<Panel: View>: ViewModifier {
    let popup: LookupPopupModel?
    let service: LookupService
    let anchor: CGRect?
    let space: LookupAnchorSpace
    let beside: Bool
    let onClose: () -> Void
    let panel: (LookupPopupModel) -> Panel
    /// Where this view is in the window, for a `.local` anchor.
    @State private var origin: CGPoint = .zero

    func body(content: Content) -> some View {
        let global = anchor.map { space == .local ? $0.offsetBy(dx: origin.x, dy: origin.y) : $0 } ?? popup?.anchor
        content
            .environment(\.closeLookup, popup == nil ? nil : CloseLookupAction(onClose))
            .onGeometryChange(for: CGPoint.self) { $0.frame(in: .global).origin } action: { origin = $0 }
            .overlay {
                LookupOverlayHost(popup: popup, service: service, anchor: global, beside: beside, onClose: onClose, panel: panel)
            }
    }
}

struct LookupOverlayHost<Panel: View>: View {
    let popup: LookupPopupModel?
    let service: LookupService
    /// In window coordinates.
    let anchor: CGRect?
    let beside: Bool
    let onClose: () -> Void
    let panel: (LookupPopupModel) -> Panel
    @State private var tall = false
    @State private var drag: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            if let popup {
                ZStack {
                    if LookupOverlayPlacement.usesBottomPanel(geometry.size) {
                        bottomPanel(popup, geometry: geometry)
                    } else {
                        let origin = geometry.frame(in: .global).origin
                        let local = anchor.map { $0.offsetBy(dx: -origin.x, dy: -origin.y) }
                        let frame = LookupOverlayPlacement.cardFrame(anchor: local, in: CGRect(origin: .zero, size: geometry.size), beside: beside)
                        chrome(popup)
                            .frame(width: frame.width, height: frame.height)
                            .position(x: frame.midX, y: frame.midY)
                            .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    }
                }
            }
        }
        .animation(.spring(duration: 0.3), value: popup?.id)
        .onChange(of: popup?.id) { tall = false; drag = 0 }
    }

    /// A narrow screen: half the height, pulled up to almost all of it or down to close. It
    /// floats above the home indicator and a tab bar (the safe area), like a card.
    private func bottomPanel(_ popup: LookupPopupModel, geometry: GeometryProxy) -> some View {
        let full = geometry.size.height
        let height = (tall ? full - 8 : full * 0.55) - drag
        return VStack(spacing: 0) {
            Spacer(minLength: 0)
            // A little above the panel also takes the drag, so it's easy to catch.
            Color.clear
                .frame(height: 16)
                .contentShape(.rect)
                .onTapGesture(perform: onClose)
                .gesture(resize)
            chrome(popup, handle: true)
                .frame(height: min(max(height, 120), full - 16), alignment: .top)
                .padding(.bottom, 6)
        }
        .transition(.move(edge: .bottom))
    }

    private func chrome(_ popup: LookupPopupModel, handle: Bool = false) -> some View {
        VStack(spacing: 0) {
            if handle { handleBar }
            panel(popup)
        }
        .foregroundStyle(.primary)
        .lookupPopupBackground(service)
        // What's behind is lightly blurred (the lightest material, half strength), so text stays
        // readable at low opacity while the colours behind still come through.
        .background { Rectangle().fill(.ultraThinMaterial).opacity(0.5) }
        // Esc (no visible close button: a tap elsewhere closes it).
        .background {
            Button("Close Dictionary", action: onClose)
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .clipShape(.rect(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(.separator, lineWidth: 0.5) }
        .shadow(color: .black.opacity(0.25), radius: 18, y: 6)
        .padding(.horizontal, handle ? 6 : 0)
        .accessibilityElement(children: .contain)
        .accessibilityAction(.escape, onClose)
        .accessibilityIdentifier("lookup.overlay")
    }

    /// The bottom panel's top edge, all of it a handle that resizes the panel.
    private var handleBar: some View {
        Capsule().fill(.secondary.opacity(0.5)).frame(width: 40, height: 5)
            .frame(maxWidth: .infinity)
            .frame(height: 32)
            .contentShape(.rect)
            .gesture(resize)
            .accessibilityElement()
            .accessibilityLabel("Dictionary size")
            .accessibilityValue(tall ? "Full" : "Half")
            .accessibilityAdjustableAction { direction in
                if direction == .increment { tall = true } else if tall { tall = false } else { onClose() }
            }
            .accessibilityIdentifier("lookup.handle")
    }

    /// Drag the bottom panel's top: up for the full height, down for half, down again to close.
    /// A short flick is enough, so closing never needs a swipe down to the screen's edge.
    private var resize: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { drag = $0.translation.height }
            .onEnded { value in
                let moved = value.predictedEndTranslation.height
                withAnimation(.spring(duration: 0.3)) {
                    drag = 0
                    if moved < -40 {
                        tall = true
                    } else if moved > 50 {
                        if tall { tall = false } else { onClose() }
                    }
                }
            }
    }
}

/// Closes the open lookup popup, for a tap that missed a word (`lookupOverlay` sets it in the
/// environment of the view it's attached to while a popup is open).
public struct CloseLookupAction {
    let close: () -> Void

    init(_ close: @escaping () -> Void) {
        self.close = close
    }

    public func callAsFunction() {
        close()
    }
}

public extension EnvironmentValues {
    @Entry var closeLookup: CloseLookupAction?
}
