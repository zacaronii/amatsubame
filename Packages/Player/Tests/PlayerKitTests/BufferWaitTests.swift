import Foundation
import Testing
@testable import PlayerKit

struct BufferWaitTests {
    @Test func gathersMoreEachTimeTheStreamRunsDryAgainSoon() {
        var wait = BufferWait()
        let start = Date(timeIntervalSince1970: 1000)
        #expect(wait.seconds == 2)
        // The first time says nothing about the connection yet.
        #expect(wait.note(buffering: true, at: start) == false)
        #expect(wait.note(buffering: false, at: start.addingTimeInterval(3)) == false)
        // Again eight seconds later, and again: more each time, up to the top.
        #expect(wait.note(buffering: true, at: start.addingTimeInterval(11)) == true)
        #expect(wait.seconds == 6)
        _ = wait.note(buffering: false, at: start.addingTimeInterval(20))
        _ = wait.note(buffering: true, at: start.addingTimeInterval(40))
        #expect(wait.seconds == 12)
        _ = wait.note(buffering: false, at: start.addingTimeInterval(60))
        _ = wait.note(buffering: true, at: start.addingTimeInterval(90))
        _ = wait.note(buffering: false, at: start.addingTimeInterval(120))
        #expect(wait.note(buffering: true, at: start.addingTimeInterval(150)) == false, "already at the top")
        #expect(wait.seconds == 20)
    }

    @Test func comesBackDownAfterALongCleanRunAndIgnoresSeeks() {
        var wait = BufferWait()
        let start = Date(timeIntervalSince1970: 1000)
        _ = wait.note(buffering: true, at: start)
        _ = wait.note(buffering: false, at: start.addingTimeInterval(2))
        _ = wait.note(buffering: true, at: start.addingTimeInterval(10))
        _ = wait.note(buffering: false, at: start.addingTimeInterval(16))
        #expect(wait.seconds == 6)
        // A seek refills: not the connection's doing.
        wait.noteSeek(at: start.addingTimeInterval(30))
        #expect(wait.note(buffering: true, at: start.addingTimeInterval(31)) == false)
        _ = wait.note(buffering: false, at: start.addingTimeInterval(32))
        #expect(wait.seconds == 6)
        // Ten minutes without a wait, then one: a step down.
        #expect(wait.note(buffering: true, at: start.addingTimeInterval(632)) == true)
        #expect(wait.seconds == 2)
    }
}
