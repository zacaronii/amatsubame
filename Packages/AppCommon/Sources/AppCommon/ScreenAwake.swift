#if canImport(UIKit)
import UIKit
#endif

/// Keeps the screen from dimming while something plays that you watch or read along with
/// (mpv and AVPlayer don't do it themselves outside Apple's own player views), or while a book
/// or manga is being read.
@MainActor
public enum ScreenAwake {
    /// Why the screen is kept on: it sleeps again when no reason is left.
    private static var reasons: Set<String> = []

    public static func set(_ awake: Bool, reason: String = "playing") {
        if awake { reasons.insert(reason) } else { reasons.remove(reason) }
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = !reasons.isEmpty
        #endif
    }

    /// For tests.
    static var isKeepingAwake: Bool { !reasons.isEmpty }
}
