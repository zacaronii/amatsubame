import SwiftUI

/// The readers' progress line along the very bottom edge of the screen: 3 pt
/// thick, 2.5 pt up, straight across the whole width and stopping where the screen's rounded
/// corners begin. 0–100% maps onto that visible length. Place it in a view that ignores the
/// safe area; the home indicator may sit over it.
struct ReaderProgressBar: View {
    let fraction: Double
    /// Fills from the right (right-to-left books and manga).
    let rightToLeft: Bool
    /// The track's colour (the page's ink); the read part is the app's accent.
    let track: Color

    static let thickness: CGFloat = 3
    static let lift: CGFloat = 2.5

    var body: some View {
        GeometryReader { geometry in
            let inset = Self.cornerInset(radius: Self.cornerRadius(screen: geometry.size))
            let length = max(geometry.size.width - inset * 2, 0)
            ZStack(alignment: rightToLeft ? .trailing : .leading) {
                Rectangle().fill(track.opacity(0.18))
                Rectangle().fill(Color.accentColor)
                    .frame(width: length * min(max(fraction, 0), 1))
            }
            .frame(width: length, height: Self.thickness)
            .position(x: geometry.size.width / 2, y: geometry.size.height - Self.lift - Self.thickness / 2)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// How far in from each side a straight line `lift` above the bottom edge leaves a corner of
    /// `radius`: where the curve crosses its lower edge.
    static func cornerInset(radius: CGFloat) -> CGFloat {
        guard radius > lift else { return 0 }
        let rise = radius - lift
        return (radius - (radius * radius - rise * rise).squareRoot()).rounded(.up)
    }

    /// The screen's corner radius, from its size in points (either way round): Apple doesn't
    /// publish it, so this is a table of current devices, with a typical radius for other
    /// rounded screens. The Mac's window has none worth avoiding.
    static func cornerRadius(screen: CGSize) -> CGFloat {
        #if os(iOS)
        let size = [Int(min(screen.width, screen.height).rounded()), Int(max(screen.width, screen.height).rounded())]
        switch (size[0], size[1]) {
        case (375, 667), (414, 736), (320, 568): return 0          // iPhone SE, 8 Plus: square corners
        case (768, 1024), (810, 1080): return 0                    // older iPads
        case (375, 812): return 44                                 // iPhone X–11 Pro, 12/13 mini
        case (414, 896): return 41                                 // iPhone XR, 11, XS Max, 11 Pro Max
        case (390, 844): return 47                                 // iPhone 12–14
        case (428, 926): return 53                                 // iPhone 12/13 Pro Max, 14 Plus
        case (393, 852), (430, 932): return 55                     // iPhone 14 Pro–16, 14 Pro Max–16 Plus
        case (402, 874), (440, 956), (420, 912): return 62         // iPhone 16 Pro–17 Pro Max, Air
        case (466, 678): return 50                                 // iPhone Duo folded
        case (669, 951): return 38                                 // iPhone Duo open
        case (744, 1133): return 21                                // iPad mini 6 and 7
        case (820, 1180), (834, 1194), (834, 1210), (1024, 1366), (1032, 1376): return 18 // iPad Air, Pro
        default: return 40
        }
        #else
        return 0
        #endif
    }
}
