import Foundation
@testable import PlayerKit
import Testing

@Suite struct CondensedTests {
    func track(_ times: [(Double, Double)]) -> SubtitleTrack {
        SubtitleTrack(cues: times.enumerated().map { SubtitleCue(id: $0.offset, start: $0.element.0, end: $0.element.1, text: "台詞\($0.offset)") })
    }

    @Test func skipsLongGapsKeepingALittleEachSide() {
        let stretches = track([(10, 12), (13, 15), (25, 27), (28.5, 30)]).silentStretches()
        // Before the first line (the opening), and the 10 s gap; the 1 s and 1.5 s gaps stay.
        #expect(stretches == [0...9.5, 15.3...24.5])
    }

    @Test func overlappingLinesAndTheEndingAreKept() {
        // The second line starts before the first ends: no gap. Nothing after the last line.
        let stretches = track([(2, 10), (8, 12), (12.5, 14)]).silentStretches()
        #expect(stretches.isEmpty, "\(stretches)")
        #expect(track([]).silentStretches().isEmpty)
    }

    @Test func aGapJustOverTheLimitStillLeavesSomethingToSkip() {
        // 3.2 s gap: from end + 0.3 to start - 0.5 is 2.4 s.
        #expect(track([(5, 6), (9.2, 10)]).silentStretches() == [0...4.5, 6.3...8.7])
        // Exactly 3 s isn't over: kept.
        #expect(track([(5, 6), (9, 10)]).silentStretches() == [0...4.5])
    }
}
