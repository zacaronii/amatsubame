import Foundation
@testable import Miru
import Testing

@MainActor @Suite struct FeedHoldTests {
    @Test func holdsWhileTouchingAndBrieflyAfter() {
        var hold = FeedHold()
        let start = Date(timeIntervalSince1970: 1000)
        #expect(!hold.isHeld(at: start))
        hold.touch()
        #expect(hold.isHeld(at: start.addingTimeInterval(60)))
        hold.release(at: start)
        #expect(hold.isHeld(at: start.addingTimeInterval(1)))
        #expect(!hold.isHeld(at: start.addingTimeInterval(1.6)))
    }
}
