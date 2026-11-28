#if os(iOS)
import AVKit
import PlayerKit
import SwiftUI
import UIKit

/// The video on a connected screen (AirPlay mirroring to a TV, or a cable): Miru shows the
/// picture there, full screen, and the phone or iPad keeps the controls and the tappable
/// Japanese lines, a better place to read and look up from. iOS gives the screen its own scene
/// (`ExternalDisplaySceneDelegate`, routed by `MiruAppDelegate`).
@MainActor @Observable
final class ExternalDisplay {
    static let shared = ExternalDisplay()
    /// A screen is connected (its scene is up).
    private(set) var isConnected = false
    private(set) var screenName = "the Other Screen"
    /// The player on screen now, set by the player while it's open.
    var player: (any PlayerEngine)?

    /// The picture is on the other screen (only while something is playing).
    var showsVideo: Bool { isConnected && player != nil }

    func connected(name: String?) {
        isConnected = true
        screenName = name.flatMap { $0.isEmpty ? nil : $0 } ?? "the Other Screen"
    }

    func disconnected() {
        isConnected = false
    }

    #if DEBUG
    /// UI tests: as if a screen were connected (the simulator has none to attach).
    func simulateConnected() { connected(name: "Test Display") }
    #endif
}

/// The external screen's window: the video when something plays, Miru's name otherwise.
final class ExternalDisplaySceneDelegate: NSObject, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: ExternalVideoView())
        window.isHidden = false
        self.window = window
        // iOS doesn't name the screen (a TV over AirPlay, a monitor on a cable).
        MainActor.assumeIsolated { ExternalDisplay.shared.connected(name: nil) }
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        window = nil
        MainActor.assumeIsolated { ExternalDisplay.shared.disconnected() }
    }
}

struct ExternalVideoView: View {
    @State private var display = ExternalDisplay.shared

    var body: some View {
        ZStack {
            Color.black
            if let player = display.player {
                // The one video layer moves here from the phone's player (and back after).
                player.videoView(fills: false)
            } else {
                Text("Miru").font(.largeTitle.weight(.semibold)).foregroundStyle(.white.opacity(0.4))
            }
        }
        .ignoresSafeArea()
    }
}

/// Routes the external screen's scene to `ExternalDisplaySceneDelegate`; every other scene is
/// SwiftUI's.
final class MiruAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: session.role)
        if session.role == .windowExternalDisplayNonInteractive {
            configuration.delegateClass = ExternalDisplaySceneDelegate.self
        }
        return configuration
    }
}

/// AirPlay: the system's route picker, TVs first (a TV gets the picture, a speaker the sound).
struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerViewHost { AVRoutePickerViewHost() }
    func updateUIView(_ view: AVRoutePickerViewHost, context: Context) {}
}

final class AVRoutePickerViewHost: UIView {
    init() {
        super.init(frame: .zero)
        let picker = AVRoutePickerView()
        picker.tintColor = .white
        picker.activeTintColor = UIColor(named: "AccentColor") ?? .systemPurple
        picker.prioritizesVideoDevices = true
        picker.translatesAutoresizingMaskIntoConstraints = false
        addSubview(picker)
        NSLayoutConstraint.activate([
            picker.leadingAnchor.constraint(equalTo: leadingAnchor), picker.trailingAnchor.constraint(equalTo: trailingAnchor),
            picker.topAnchor.constraint(equalTo: topAnchor), picker.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) { nil }

    #if DEBUG
    /// UI tests: a touch reached the picker's button (the simulator has no AirPlay, so its
    /// picker shows nothing): the player says so (`airPlayPickerTappedForTests`).
    static let tappedForTests = Notification.Name("airPlayPickerTappedForTests")

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let view = super.hitTest(point, with: event)
        if view is UIButton, event?.type == .touches, ProcessInfo.processInfo.environment["UITEST_PLAYER"] != nil {
            NotificationCenter.default.post(name: Self.tappedForTests, object: nil)
        }
        return view
    }
    #endif
}
#endif
