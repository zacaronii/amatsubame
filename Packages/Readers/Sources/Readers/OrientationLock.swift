#if os(iOS)
import UIKit

/// Lock Rotation in the readers (their settings sheets): while a reader is open with it on,
/// the screen keeps the orientation it had, whatever way the device is turned (reading lying
/// down). The app's delegate returns `mask` as its supported orientations.
@MainActor
public enum OrientationLock {
    static let key = "reader.locksRotation"
    public private(set) static var mask: UIInterfaceOrientationMask = .all

    public static var isOn: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set {
            UserDefaults.standard.set(newValue, forKey: key)
            if newValue { hold() } else { release() }
        }
    }

    /// A reader opened: hold the orientation showing, when the setting is on.
    public static func readerOpened() {
        if isOn { hold() }
    }

    /// The reader closed: the app turns freely again.
    public static func release() {
        mask = .all
        update()
    }

    private static func hold() {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        mask = switch scene.interfaceOrientation {
        case .landscapeLeft: .landscapeLeft
        case .landscapeRight: .landscapeRight
        case .portraitUpsideDown: .portraitUpsideDown
        default: .portrait
        }
        update()
    }

    private static func update() {
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
            scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        }
    }
}
#endif
