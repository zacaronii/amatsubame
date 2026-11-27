import Foundation
import Testing
@testable import PlayerKit

struct StuckWatchTests {
    let start = Date(timeIntervalSince1970: 1000)

    @Test func saysWhenPlaybackStopsMovingAndWhenItMovesAgain() {
        var watch = StuckWatch()
        #expect(watch.check(position: 754, playing: true, at: start) == nil)
        #expect(watch.check(position: 754, playing: true, at: start + 2) == nil, "not long enough yet")
        #expect(watch.check(position: 754, playing: true, at: start + 3)
                == "Stuck at 12:34 for 3.0 s (not paused, not waiting for the stream; stuck 1)")
        #expect(watch.check(position: 754, playing: true, at: start + 6) == nil, "said once")
        #expect(watch.check(position: 755, playing: true, at: start + 7) == "Was stuck at 12:34 for 7.0 s, until moving again")
        #expect(watch.summary == "1 time · 7.0 s")
    }

    @Test func pausesAndWaitsAreNotHangs() {
        var watch = StuckWatch()
        _ = watch.check(position: 10, playing: true, at: start)
        #expect(watch.check(position: 10, playing: false, at: start + 5) == nil, "paused before it counted")
        #expect(watch.check(position: 10, playing: true, at: start + 6) == nil, "the clock starts again")
        #expect(watch.check(position: 10, playing: true, at: start + 8) == nil)
        #expect(watch.summary == nil)
    }

    @Test func aHangEndedByAPauseSaysSo() {
        var watch = StuckWatch()
        _ = watch.check(position: 3700, playing: true, at: start)
        _ = watch.check(position: 3700, playing: true, at: start + 4)
        #expect(watch.check(position: 3700, playing: false, at: start + 10)
                == "Was stuck at 1:01:40 for 10.0 s, until paused or waiting for the stream")
        _ = watch.check(position: 3700, playing: true, at: start + 11)
        _ = watch.check(position: 3700, playing: true, at: start + 14)
        #expect(watch.summary == "2 times · 10.0 s", "the second one hasn't ended yet")
    }
}
