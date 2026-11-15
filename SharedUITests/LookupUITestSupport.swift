import XCTest

extension XCUIApplication {
    /// Closes the lookup popup: a swipe down on the bottom panel's handle, or Esc for a card (a
    /// tap outside it would look up whatever word is there).
    func closeLookup() {
        let handle = descendants(matching: .any)["lookup.handle"].firstMatch
        if handle.exists {
            handle.swipeDown()
        } else {
            typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        }
    }
}
