import SwiftUI

/// Pinch-to-zoom around SwiftUI content using the platform's native scroll
/// view. At 1× it doesn't scroll, so swipes reach the paging scroll view.
struct ZoomableContainer<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ZoomableRepresentable(content: AnyView(content))
    }
}

#if os(iOS)
import UIKit

private struct ZoomableRepresentable: UIViewRepresentable {
    let content: AnyView

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
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.host.rootView = content
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
        return scrollView
    }

    func updateNSView(_ scrollView: PassthroughScrollView, context: Context) {
        (scrollView.documentView as? NSHostingView<AnyView>)?.rootView = content
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
