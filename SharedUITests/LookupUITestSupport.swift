import XCTest

extension XCUIApplication {
    /// Closes the lookup popup as a person does: a tap outside it, in the largest free area
    /// around it (`lookup.close` is everything but the popup).
    func closeLookup() {
        let outside = buttons["lookup.close"]
        let area = outside.frame
        let card = descendants(matching: .any)["lookup.overlay"].firstMatch.frame
        let free = [
            CGRect(x: area.minX, y: area.minY, width: area.width, height: card.minY - area.minY),
            CGRect(x: area.minX, y: card.maxY, width: area.width, height: area.maxY - card.maxY),
            CGRect(x: area.minX, y: area.minY, width: card.minX - area.minX, height: area.height),
            CGRect(x: card.maxX, y: area.minY, width: area.maxX - card.maxX, height: area.height),
        ].max { $0.width * $0.height < $1.width * $1.height }!
        outside.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: free.midX - area.minX, dy: free.midY - area.minY))
            .tap()
    }
}
