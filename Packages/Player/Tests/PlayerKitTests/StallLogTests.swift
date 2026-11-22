import Foundation
import Testing
@testable import PlayerKit

struct StallLogTests {
    @Test func countsEachWaitAndSaysWhere() {
        var log = StallLog()
        let start = Date(timeIntervalSince1970: 1000)
        #expect(log.summary == nil)
        #expect(log.note(buffering: false, at: start, position: 5) == nil, "nothing to end")
        #expect(log.note(buffering: true, at: start, position: 754) == nil)
        #expect(log.note(buffering: true, at: start + 1, position: 754) == nil, "still the same wait")
        #expect(log.note(buffering: false, at: start + 2.5, position: 754) == "Waited 2.5 s for the stream at 12:34 (wait 1, 2.5 s in all)")
        _ = log.note(buffering: true, at: start + 60, position: 3700)
        #expect(log.note(buffering: false, at: start + 61, position: 3700) == "Waited 1.0 s for the stream at 1:01:40 (wait 2, 3.5 s in all)")
        #expect(log.summary == "2 waits · 3.5 s")
    }
}
