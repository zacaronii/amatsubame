import Foundation

/// Fixes to what the recognizer reads, before the text is matched to the lettering.
enum RecognizedText {
    /// manga-ocr (trained mostly on vertical text) fills the blank before a short centred first
    /// line of a horizontal bubble with something: often a 「 or 『 that isn't in the bubble
    /// (#13). Dropped only in a horizontal block and only when nothing after it closes it, so a
    /// real quote that closes in the same block is never touched; vertical text keeps an
    /// unpaired opener (speech quoted across two boxes). A block that is only the bracket stays.
    static func droppingStrayOpener(_ text: String, vertical: Bool) -> String {
        guard !vertical, let first = text.first, let closer = ["「": "」", "『": "』"][first], text.count > 1 else { return text }
        let rest = text.dropFirst()
        return rest.contains(Character(closer)) ? text : String(rest)
    }
}
