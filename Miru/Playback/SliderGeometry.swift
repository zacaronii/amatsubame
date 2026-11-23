import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Where a slider's thumb centre travels: from this far in from each end (half the thumb, as
/// the platform's own slider lays it out), so marks on the track sit where the thumb would.
/// SwiftUI's `Slider` draws with the platform control's geometry (on iOS 26, a 37 pt thumb).
@MainActor enum SliderGeometry {
    private static var insets: [CGSize: CGFloat] = [:]

    static func thumbInset(width: CGFloat, height: CGFloat) -> CGFloat {
        let size = CGSize(width: width.rounded(), height: height.rounded())
        guard size.width > 1, size.height > 1 else { return 0 }
        if let inset = insets[size] { return inset }
        let inset = measure(size)
        insets[size] = inset
        return inset
    }

    private static func measure(_ size: CGSize) -> CGFloat {
        #if canImport(UIKit)
        let slider = UISlider(frame: CGRect(origin: .zero, size: size))
        let bounds = slider.bounds
        let thumb = slider.thumbRect(forBounds: bounds, trackRect: slider.trackRect(forBounds: bounds), value: slider.minimumValue)
        return thumb.midX - bounds.minX
        #else
        let slider = NSSlider(frame: CGRect(origin: .zero, size: size))
        slider.minValue = 0
        slider.maxValue = 1
        slider.doubleValue = 0
        guard let cell = slider.cell as? NSSliderCell else { return 0 }
        return cell.knobRect(flipped: false).midX
        #endif
    }
}
