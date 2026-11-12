#if canImport(UIKit)
import UIKit
#endif

/// Keeps the screen from dimming while something plays that you watch or read along with
/// (mpv and AVPlayer don't do it themselves outside Apple's own player views).
@MainActor
public enum ScreenAwake {
    public static func set(_ awake: Bool) {
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = awake
        #endif
    }
}
