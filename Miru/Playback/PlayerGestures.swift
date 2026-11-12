import PlayerKit
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

extension View {
    /// The video's touch gestures (iPhone/iPad): tap for controls, two-finger tap to pause,
    /// double-tap a side to skip, drag sideways to scrub, drag an edge for brightness or volume.
    /// On the Mac a click shows the controls and a double-click goes full screen (hover, keys
    /// and menus do the rest). While `enabled` is
    /// false (the lookup panel is open) only the tap works.
    /// A sideways drag sets `scrub` (the view shows the preview) and seeks on release.
    /// The two-finger tap calls `onTwoFingerTap` (the view toggles pause without showing the
    /// controls), and the one-finger tap it also sets off is ignored.
    func playerGestures(model: PlaybackModel, size: CGSize, enabled: Bool, scrub: Binding<ScrubState?>,
                        onTwoFingerTap: @escaping () -> Void, onTap: @escaping () -> Void) -> some View {
        modifier(PlayerGestures(model: model, size: size, enabled: enabled, scrub: scrub,
                                onTwoFingerTap: onTwoFingerTap, onTap: onTap))
    }
}

private struct PlayerGestures: ViewModifier {
    let model: PlaybackModel
    let size: CGSize
    let enabled: Bool
    @Binding var scrub: ScrubState?
    let onTwoFingerTap: () -> Void
    let onTap: () -> Void

    #if os(iOS)
    enum DragMode {
        case scrub(start: Double), brightness(start: Double), volume(start: Double), ignored
    }

    @State private var dragMode: DragMode?
    @State private var level: (side: PlayerGestureMath.Side, value: Double)?
    @State private var skip = SkipAccumulator()
    @State private var skipBadge: (side: PlayerGestureMath.Side, total: Double)?
    /// When the last two-finger tap happened (the one-finger tap fires for it too).
    @State private var twoFingerTapAt = Date.distantPast
    @State private var badgeTask: Task<Void, Never>?
    @State private var originalBrightness: CGFloat?

    func body(content: Content) -> some View {
        content
            .gesture(
                SpatialTapGesture(count: 2)
                    .onEnded { value in doubleTap(at: value.location) }
                    .exclusively(before: SpatialTapGesture(count: 1).onEnded { _ in
                        guard Date().timeIntervalSince(twoFingerTapAt) > 0.6 else { return }
                        onTap()
                    }),
                including: enabled ? .all : .subviews
            )
            // While the lookup panel is open a tap only closes it: no waiting to see whether
            // it becomes a double-tap.
            .simultaneousGesture(TapGesture().onEnded(onTap), including: enabled ? .subviews : .all)
            .simultaneousGesture(drag)
            .gesture(TwoFingerTap {
                guard enabled else { return }
                twoFingerTapAt = Date()
                onTwoFingerTap()
            })
            .overlay { feedback.allowsHitTesting(false) }
            .onDisappear {
                if let originalBrightness { UIScreen.main.brightness = originalBrightness }
            }
    }

    // MARK: Gestures

    private var drag: some Gesture {
        DragGesture(minimumDistance: 15)
            .onChanged { value in
                guard enabled else { return }
                let dx = value.translation.width, dy = value.translation.height
                if dragMode == nil {
                    if abs(dx) > abs(dy) {
                        dragMode = model.mpv.duration > 0 ? .scrub(start: model.mpv.timePosition) : .ignored
                    } else {
                        switch PlayerGestureMath.edge(x: value.startLocation.x, width: size.width) {
                        case .left?:
                            if originalBrightness == nil { originalBrightness = UIScreen.main.brightness }
                            dragMode = .brightness(start: UIScreen.main.brightness)
                        case .right?: dragMode = .volume(start: model.mpv.volume / 100)
                        default: dragMode = .ignored
                        }
                    }
                }
                switch dragMode {
                case .scrub(let start)?:
                    scrub = ScrubState(start: start, target: PlayerGestureMath.scrubTarget(
                        from: start, dx: dx, width: size.width, duration: model.mpv.duration))
                case .brightness(let start)?:
                    let value = PlayerGestureMath.level(from: start, dy: dy, height: size.height)
                    UIScreen.main.brightness = value
                    level = (.left, value)
                case .volume(let start)?:
                    let value = PlayerGestureMath.level(from: start, dy: dy, height: size.height)
                    model.mpv.setVolume(value * 100)
                    level = (.right, value)
                case .ignored?, nil:
                    break
                }
            }
            .onEnded { _ in
                if case .scrub(let start)? = dragMode, let target = scrub?.target, abs(target - start) >= 1 {
                    model.mpv.seek(to: target)
                }
                if case .scrub? = dragMode { scrub = nil }
                dragMode = nil
                withAnimation(.easeOut(duration: 0.3)) { level = nil }
            }
    }

    private func doubleTap(at location: CGPoint) {
        guard enabled else {
            onTap()
            return
        }
        let side = PlayerGestureMath.third(x: location.x, width: size.width)
        let delta = skip.register(side, at: Date())
        guard delta != 0 else { return }
        model.mpv.seek(by: delta)
        showBadge { skipBadge = (side, skip.total) }
    }

    private func showBadge(_ set: () -> Void) {
        withAnimation(.easeOut(duration: 0.15)) { set() }
        badgeTask?.cancel()
        badgeTask = Task {
            try? await Task.sleep(for: .seconds(0.9))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.3)) {
                skipBadge = nil
            }
        }
    }

    // MARK: Feedback

    @ViewBuilder private var feedback: some View {
        ZStack {
            if let skipBadge {
                HStack {
                    if skipBadge.side == .right { Spacer() }
                    Label(String(format: "%+.0f s", skipBadge.total),
                          systemImage: skipBadge.side == .left ? "gobackward" : "goforward")
                        .font(.title3.weight(.semibold).monospacedDigit())
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.black.opacity(0.55), in: .capsule)
                        .padding(.horizontal, size.width * 0.08)
                    if skipBadge.side == .left { Spacer() }
                }
                .transition(.opacity)
            }
            if let level {
                HStack {
                    if level.side == .right { Spacer() }
                    VStack(spacing: 8) {
                        Image(systemName: level.side == .left ? "sun.max.fill" : "speaker.wave.2.fill")
                        GeometryReader { bar in
                            ZStack(alignment: .bottom) {
                                Capsule().fill(.white.opacity(0.25))
                                Capsule().fill(.white).frame(height: bar.size.height * level.value)
                            }
                        }
                        .frame(width: 6, height: min(size.height * 0.4, 180))
                    }
                    .padding(12)
                    .background(.black.opacity(0.5), in: .capsule)
                    .padding(.horizontal, 24)
                    if level.side == .left { Spacer() }
                }
                .transition(.opacity)
            }
        }
        .foregroundStyle(.white)
    }
    #else
    func body(content: Content) -> some View {
        // A double-click goes full screen, as in mpv. While the lookup is open, a click closes
        // it at once (no waiting to see whether it's a double-click).
        content
            .gesture(
                TapGesture(count: 2).onEnded { PlayerWindow.toggleFullScreen() }
                    .exclusively(before: TapGesture().onEnded(onTap)),
                including: enabled ? .all : .subviews
            )
            .simultaneousGesture(TapGesture().onEnded(onTap), including: enabled ? .subviews : .all)
    }
    #endif
}

#if os(iOS)
/// A tap with two fingers (UIKit; SwiftUI has no multi-touch tap).
private struct TwoFingerTap: UIGestureRecognizerRepresentable {
    let action: () -> Void

    func makeUIGestureRecognizer(context: Context) -> UITapGestureRecognizer {
        let recognizer = UITapGestureRecognizer()
        recognizer.numberOfTouchesRequired = 2
        return recognizer
    }

    func handleUIGestureRecognizerAction(_ recognizer: UITapGestureRecognizer, context: Context) {
        if recognizer.state == .ended { action() }
    }
}
#endif
