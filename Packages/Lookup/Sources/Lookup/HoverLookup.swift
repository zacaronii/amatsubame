#if os(macOS)
import AppKit
import Core
import Observation

/// The modifier keys held right now, for looking words up by pointing at them (Settings ▸
/// Popup ▸ Look Up on Hover). Followed with a local event monitor, so a key pressed while
/// the pointer already rests on a word counts too. Shared by the subtitles (`TappableLine`)
/// and the manga reader's text.
@MainActor @Observable
public final class HoverModifiers {
    public static let shared = HoverModifiers()

    public private(set) var flags: NSEvent.ModifierFlags

    private init() {
        flags = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            let held = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            MainActor.assumeIsolated { HoverModifiers.shared.flags = held }
            return event
        }
    }

    /// Whether pointing at a word looks it up now.
    public func allows(_ setting: PopupSettings.HoverLookup) -> Bool {
        Self.allows(setting, held: flags)
    }

    public static func allows(_ setting: PopupSettings.HoverLookup, held: NSEvent.ModifierFlags) -> Bool {
        switch setting {
        case .off: false
        case .always: true
        case .shift: held.contains(.shift)
        case .option: held.contains(.option)
        case .control: held.contains(.control)
        case .command: held.contains(.command)
        }
    }
}
#endif
