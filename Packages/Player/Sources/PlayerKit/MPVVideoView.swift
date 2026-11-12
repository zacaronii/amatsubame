import AVFoundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Shows an `MPVController`'s video, keeping its Metal layer sized to the view.
public struct MPVVideoView {
    let controller: MPVController

    public init(controller: MPVController) {
        self.controller = controller
    }
}

#if canImport(UIKit)
public final class MPVHostView: UIView {
    let videoLayer: MPVMetalLayer
    /// Called after the view settles at a new size (rotation, window resize).
    var onResize: (() -> Void)?
    private var lastSize: CGSize = .zero
    /// The video's shape; the layer is sized to fit it (see `videoFrame`).
    var videoAspect: Double? {
        didSet { if videoAspect != oldValue { setNeedsLayout() } }
    }

    init(layer videoLayer: MPVMetalLayer) {
        self.videoLayer = videoLayer
        super.init(frame: .zero)
        backgroundColor = .black
        videoLayer.contentsScale = UIScreen.main.scale
        videoLayer.framebufferOnly = true
        // Until mpv redraws at a new size, scale the last frame into place (not a corner).
        videoLayer.contentsGravity = .resize
        videoLayer.backgroundColor = UIColor.black.cgColor
        layer.addSublayer(videoLayer)
    }

    required init?(coder: NSCoder) { nil }

    override public func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let frame = videoFrame(in: bounds, aspect: videoAspect)
        videoLayer.frame = frame
        videoLayer.drawableSize = CGSize(width: frame.width * videoLayer.contentsScale, height: frame.height * videoLayer.contentsScale)
        CATransaction.commit()
        notifyIfResized()
    }
}

extension MPVHostView {
    /// mpv (MoltenVK context) reads the drawable size only when it reconfigures, so tell
    /// the controller whenever the size really changes (not on the first layout).
    fileprivate func notifyIfResized() {
        let size = videoLayer.frame.size
        guard size.width > 1, size.height > 1, size != lastSize else { return }
        let isFirst = lastSize == .zero
        lastSize = size
        if !isFirst { onResize?() }
    }
}

extension MPVVideoView: UIViewRepresentable {
    public func makeUIView(context: Context) -> MPVHostView {
        let view = MPVHostView(layer: controller.layer)
        view.onResize = { [controller] in controller.viewResized() }
        return view
    }
    public func updateUIView(_ view: MPVHostView, context: Context) {
        view.videoAspect = controller.videoAspect
    }
}
#else
public final class MPVHostView: NSView {
    let videoLayer: MPVMetalLayer
    /// Called after the view settles at a new size (window resize, full screen).
    var onResize: (() -> Void)?
    private var lastSize: CGSize = .zero
    /// The video's shape; the layer is sized to fit it (see `videoFrame`).
    var videoAspect: Double? {
        didSet { if videoAspect != oldValue { needsLayout = true } }
    }

    init(layer videoLayer: MPVMetalLayer) {
        self.videoLayer = videoLayer
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        videoLayer.framebufferOnly = true
        layer?.addSublayer(videoLayer)
    }

    required init?(coder: NSCoder) { nil }

    override public func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let scale = window?.backingScaleFactor ?? 2
        videoLayer.contentsScale = scale
        let frame = videoFrame(in: bounds, aspect: videoAspect)
        videoLayer.frame = frame
        videoLayer.drawableSize = CGSize(width: frame.width * scale, height: frame.height * scale)
        CATransaction.commit()
        notifyIfResized()
    }
}

extension MPVHostView {
    /// See the UIKit version: mpv only picks up a new drawable size when it reconfigures.
    fileprivate func notifyIfResized() {
        let size = videoLayer.frame.size
        guard size.width > 1, size.height > 1, size != lastSize else { return }
        let isFirst = lastSize == .zero
        lastSize = size
        if !isFirst { onResize?() }
    }
}

extension MPVVideoView: NSViewRepresentable {
    public func makeNSView(context: Context) -> MPVHostView {
        let view = MPVHostView(layer: controller.layer)
        view.onResize = { [controller] in controller.viewResized() }
        return view
    }
    public func updateNSView(_ view: MPVHostView, context: Context) {
        view.videoAspect = controller.videoAspect
    }
}
#endif

/// Where the video layer goes: the largest rect of the video's shape centred in `bounds`
/// (the whole of `bounds` until the shape is known). With the drawable always the video's
/// shape, a frame drawn before a rotation is only scaled until mpv catches up, never squashed.
func videoFrame(in bounds: CGRect, aspect: Double?) -> CGRect {
    guard let aspect, aspect > 0, bounds.width > 1, bounds.height > 1 else { return bounds }
    return AVMakeRect(aspectRatio: CGSize(width: aspect, height: 1), insideRect: bounds)
}
