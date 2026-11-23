import Foundation
@testable import Readers
import Testing

@MainActor @Suite struct AutoScrollTests {
    let start = Date(timeIntervalSinceReferenceDate: 1_000_000)

    /// Thirty minutes with no touch, key, pointer move or lookup: it stops; any of them starts
    /// the thirty minutes again.
    @Test func itStopsAfterThirtyMinutesWithoutInput() {
        let scroll = AutoScroll()
        scroll.start(now: start)
        #expect(!scroll.checkIdle(now: start.addingTimeInterval(29 * 60)))
        #expect(scroll.isOn)
        scroll.noteInput(now: start.addingTimeInterval(29 * 60))
        #expect(!scroll.checkIdle(now: start.addingTimeInterval(58 * 60)), "an input started the limit again")
        #expect(scroll.checkIdle(now: start.addingTimeInterval(59 * 60)))
        #expect(!scroll.isOn && scroll.stoppedIdle)
        #expect(AutoScroll.idleStops(lastInput: start, now: start.addingTimeInterval(AutoScroll.idleLimit)))
        #expect(!AutoScroll.idleStops(lastInput: start, now: start.addingTimeInterval(AutoScroll.idleLimit - 1)))
    }

    @Test func startingAgainClearsTheIdleStop() {
        let scroll = AutoScroll()
        scroll.start(now: start)
        scroll.checkIdle(now: start.addingTimeInterval(31 * 60))
        scroll.start(now: start.addingTimeInterval(32 * 60))
        #expect(scroll.isOn && !scroll.stoppedIdle)
        #expect(!scroll.checkIdle(now: start.addingTimeInterval(33 * 60)))
    }

    @Test func pausesHoldItUntilAllAreGone() {
        let scroll = AutoScroll()
        scroll.start(now: start)
        #expect(scroll.isMoving)
        scroll.set(.controls, true)
        scroll.set(.lookup, true)
        #expect(!scroll.isMoving)
        scroll.set(.controls, false)
        #expect(!scroll.isMoving, "the lookup is still open")
        scroll.set(.lookup, false)
        #expect(scroll.isMoving)
        scroll.stop()
        #expect(!scroll.isMoving)
    }

    @Test func mangaLevelsGoFromSlowToSkim() {
        #expect(abs(AutoScroll.mangaPointsPerSecond(level: 1) - 20) < 0.001)
        #expect(abs(AutoScroll.mangaPointsPerSecond(level: 10) - 200) < 0.001)
        #expect(AutoScroll.mangaPointsPerSecond(level: 5) > AutoScroll.mangaPointsPerSecond(level: 4))
        #expect(AutoScroll.mangaPointsPerSecond(level: 0) == AutoScroll.mangaPointsPerSecond(level: 1), "clamped")
    }

    /// 300 characters a minute on 20-point text, 1.7 line height, lines 400 points long
    /// (20 characters): 15 lines a minute, 34 points each, so 8.5 points a second.
    @Test func bookSpeedFollowsTheReadingRate() {
        let speed = AutoScroll.bookPointsPerSecond(charactersPerMinute: 300, fontSize: 20, lineAdvance: 34, lineLength: 400)
        #expect(abs(speed - 8.5) < 0.0001)
        // Twice the font on the same line: half the characters per line, twice the advance.
        #expect(abs(AutoScroll.bookPointsPerSecond(charactersPerMinute: 300, fontSize: 40, lineAdvance: 68, lineLength: 400) - 34) < 0.0001)
        #expect(AutoScroll.bookPointsPerSecond(charactersPerMinute: 300, fontSize: 0, lineAdvance: 34, lineLength: 400) == 0)
    }
}
