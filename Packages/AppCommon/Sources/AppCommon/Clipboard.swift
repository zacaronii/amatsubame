#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// The system clipboard, the same call on every platform.
public enum Clipboard {
    public static func copy(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}
