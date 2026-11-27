@testable import PlayerEngine
import Testing

/// Pause After Each Line's "call me at time T" for an engine that reports its time in steps:
/// once, going forward, never on a seek.
@MainActor @Suite struct TimeBoundaryTests {
    @Test func crossingIsForwardAndShort() {
        let boundary = TimeBoundary(time: 10, action: {})
        #expect(boundary.isCrossed(from: 9.96, to: 10.0))
        #expect(boundary.isCrossed(from: 9.9, to: 10.3))
        #expect(!boundary.isCrossed(from: 10.0, to: 10.04), "already past it")
        #expect(!boundary.isCrossed(from: 9.9, to: 9.95), "not there yet")
        #expect(!boundary.isCrossed(from: 4, to: 12), "a seek across it")
        #expect(!boundary.isCrossed(from: 12, to: 9), "backwards")
    }

}
