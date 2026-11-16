import XCTest

extension XCUIApplication {
    /// Closes the lookup popup: a swipe down on the bottom panel's handle; for a card, a tap at
    /// `outside` (a spot with no word: a word there would be looked up instead), else Esc (the
    /// Mac; the iOS Simulator doesn't pass Esc on).
    func closeLookup(outside: XCUICoordinate? = nil) {
        let handle = descendants(matching: .any)["lookup.handle"].firstMatch
        if handle.exists {
            handle.swipeDown()
        } else if let outside {
            outside.tap()
        } else {
            typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        }
    }
}
