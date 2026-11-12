import AVFoundation
import CoreGraphics

/// How the player arranges the picture and its controls, from the screen's shape and fold.
/// Rects are in screen coordinates (safe areas included).
nonisolated enum PlayerLayout: Equatable {
    /// The controls over the picture: a phone held sideways, where the picture fills the screen.
    case overlay
    /// The picture fills the width with black bars above and below, roomy enough for the
    /// title and buttons (top) and the scrubber (bottom): only the subtitle sits on the picture.
    case bars(video: CGRect, top: CGRect, bottom: CGRect)
    /// The picture at the top, the scrubber, line buttons and Lines strip under it: portrait,
    /// or half open like a laptop (the fold across, the picture above it).
    case split(video: CGRect, panel: CGRect)

    /// Shortest bar that holds the 48 pt buttons.
    static let minimumBar: CGFloat = 52
    /// Shortest panel worth having: the scrubber, the buttons and a few lines.
    static let minimumPanel: CGFloat = 260

    /// - Parameters:
    ///   - screen: the whole screen; `safe`: the part clear of the Dynamic Island, the status
    ///     column and the home indicator.
    ///   - aspect: the video's width / height once known (16:9 until then).
    ///   - fold: the crease (with its margins), if the screen has one.
    static func make(screen: CGRect, safe: CGRect, aspect: Double?, fold: CGRect?) -> PlayerLayout {
        let aspect = aspect.flatMap { $0 > 0 ? CGFloat($0) : nil } ?? 16 / 9
        if let fold, fold.width > fold.height {
            // The crease runs across: the picture above it, the controls below.
            let above = CGRect(x: safe.minX, y: safe.minY, width: safe.width, height: max(fold.minY - safe.minY, 0))
            let panel = CGRect(x: safe.minX, y: fold.maxY, width: safe.width, height: max(safe.maxY - fold.maxY, 0))
            if panel.height >= minimumPanel, above.height > 100 {
                return .split(video: AVMakeRect(aspectRatio: CGSize(width: aspect, height: 1), insideRect: above), panel: panel)
            }
        }
        if screen.height > screen.width {
            // Portrait: the picture across the top, everything else under it.
            let height = (safe.width / aspect).rounded()
            let video = CGRect(x: safe.minX, y: safe.minY, width: safe.width, height: height)
            let panel = CGRect(x: safe.minX, y: video.maxY, width: safe.width, height: safe.maxY - video.maxY)
            return panel.height >= minimumPanel ? .split(video: video, panel: panel) : .overlay
        }
        // Sideways: the picture fills the screen's width when the screen is taller than the video.
        let video = AVMakeRect(aspectRatio: CGSize(width: aspect, height: 1), insideRect: screen)
        let top = CGRect(x: safe.minX, y: screen.minY, width: safe.width, height: video.minY - screen.minY)
        let bottom = CGRect(x: safe.minX, y: video.maxY, width: safe.width, height: screen.maxY - video.maxY)
        guard top.height >= minimumBar, bottom.height >= minimumBar else { return .overlay }
        return .bars(video: video, top: top, bottom: bottom)
    }
}
