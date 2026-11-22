import SwiftUI

/// Pinch-to-zoom around SwiftUI content using the platform's native scroll
/// view. At 1× it doesn't scroll, so swipes reach the paging scroll view.
struct ZoomableContainer<Content: View>: View {
    let content: Content
    var control: ZoomControl?

    init(control: ZoomControl? = nil, @ViewBuilder content: () -> Content) {
        self.content = content()
        self.control = control
    }

    var body: some View {
        ZoomableRepresentable(content: AnyView(content), control: control)
    }
}

/// Zooms a `ZoomableContainer` from its content (a double tap): in to `ZoomControl.scale`
/// around a point, or back out when it's already zoomed.
@MainActor
final class ZoomControl {
    static let scale: CGFloat = 2.5
    fileprivate var toggle: ((CGPoint) -> Void)?

    /// `point`: where to zoom in on, in the content's own coordinates.
    func toggleZoom(at point: CGPoint) {
        toggle?(point)
    }
}

#if os(iOS)
import UIKit

private struct ZoomableRepresentable: UIViewRepresentable {
    let content: AnyView
    var control: ZoomControl?

    func makeCoordinator() -> Coordinator { Coordinator(UIHostingController(rootView: content)) }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = CenteringScrollView()
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 4
        scrollView.bouncesZoom = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.backgroundColor = .clear
        // At 1× its pan stays out of page swipes; pinching turns it back on.
        scrollView.panGestureRecognizer.isEnabled = false
        let hosted = context.coordinator.host.view!
        hosted.backgroundColor = .clear
        scrollView.addSubview(hosted)
        scrollView.hosted = hosted
        connect(scrollView)
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.host.rootView = content
        connect(scrollView)
    }

    private func connect(_ scrollView: UIScrollView) {
        control?.toggle = { [weak scrollView] point in
            guard let scrollView else { return }
            if scrollView.zoomScale > scrollView.minimumZoomScale + 0.001 {
                scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
            } else {
                let size = CGSize(width: scrollView.bounds.width / ZoomControl.scale, height: scrollView.bounds.height / ZoomControl.scale)
                scrollView.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true)
            }
        }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        let host: UIHostingController<AnyView>
        init(_ host: UIHostingController<AnyView>) { self.host = host }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { host.view }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            scrollView.panGestureRecognizer.isEnabled = scrollView.zoomScale > scrollView.minimumZoomScale + 0.001
        }
    }

    final class CenteringScrollView: UIScrollView {
        weak var hosted: UIView?

        override func layoutSubviews() {
            super.layoutSubviews()
            guard let hosted else { return }
            if zoomScale <= minimumZoomScale + 0.001 {
                hosted.frame = CGRect(origin: .zero, size: bounds.size)
                contentSize = bounds.size
            }
        }
    }
}
#else
import AppKit

private struct ZoomableRepresentable: NSViewRepresentable {
    let content: AnyView
    var control: ZoomControl?

    func makeNSView(context: Context) -> PassthroughScrollView {
        let scrollView = PassthroughScrollView()
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 1
        scrollView.maxMagnification = 4
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        let hosted = NSHostingView(rootView: content)
        hosted.translatesAutoresizingMaskIntoConstraints = true
        hosted.autoresizingMask = [.width, .height]
        scrollView.documentView = hosted
        connect(scrollView)
        return scrollView
    }

    func updateNSView(_ scrollView: PassthroughScrollView, context: Context) {
        (scrollView.documentView as? NSHostingView<AnyView>)?.rootView = content
        connect(scrollView)
    }

    private func connect(_ scrollView: PassthroughScrollView) {
        control?.toggle = { [weak scrollView] point in
            guard let scrollView else { return }
            let zoomed = scrollView.magnification > scrollView.minMagnification + 0.01
            // The hosting view is flipped like SwiftUI: the point is already in its coordinates.
            scrollView.animator().setMagnification(zoomed ? scrollView.minMagnification : ZoomControl.scale, centeredAt: point)
        }
    }

    /// Passes scroll-wheel/trackpad scrolling to the paging scroll view unless zoomed in.
    final class PassthroughScrollView: NSScrollView {
        override func scrollWheel(with event: NSEvent) {
            if magnification <= minMagnification + 0.01 {
                nextResponder?.scrollWheel(with: event)
            } else {
                super.scrollWheel(with: event)
            }
        }

        override func layout() {
            super.layout()
            if magnification <= minMagnification + 0.01 {
                documentView?.frame = CGRect(origin: .zero, size: contentSize)
            }
        }
    }
}
#endif
