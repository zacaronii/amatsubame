import Core
import Foundation
@testable import Kiku
import Testing

@MainActor @Suite struct SleepTimerAndFindTests {
    let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

    @Test func theVolumeFadesOverTheLastHalfMinute() {
        let timer = PlaybackModel.SleepTimer.minutes(15, ends: now.addingTimeInterval(60))
        #expect(SleepTimerRules.volume(remaining: SleepTimerRules.remaining(timer, now: now, time: 0, stopsAt: 0, rate: 1)) == 1)
        let half = SleepTimerRules.remaining(timer, now: now.addingTimeInterval(45), time: 0, stopsAt: 0, rate: 1)
        #expect(abs(SleepTimerRules.volume(remaining: half) - 0.5) < 0.001)
        #expect(SleepTimerRules.volume(remaining: SleepTimerRules.remaining(timer, now: now.addingTimeInterval(70), time: 0, stopsAt: 0, rate: 1)) == 0)
        #expect(SleepTimerRules.volume(remaining: nil) == 1, "nothing known: full")
    }

    @Test func chapterAndEpisodeEndsCountAtTheSpeedPlaying() {
        // 30 s of audio at double speed is 15 s of listening: halfway down.
        #expect(SleepTimerRules.remaining(.endOfChapter(end: 130), now: now, time: 100, stopsAt: 0, rate: 2) == 15)
        #expect(SleepTimerRules.remaining(.endOfEpisode, now: now, time: 590, stopsAt: 600, rate: 1) == 10)
        #expect(SleepTimerRules.remaining(.endOfEpisode, now: now, time: 10, stopsAt: 0, rate: 1) == nil, "length not known yet")
    }

    @Test func aShakeRestartsOrBringsBackOnlyATimerOfMinutes() {
        let running = PlaybackModel.SleepTimer.minutes(30, ends: now.addingTimeInterval(5))
        #expect(SleepTimerRules.shake(timer: running, lastMinutes: 30, stoppedAt: nil, now: now) == .restart(minutes: 30))
        #expect(SleepTimerRules.shake(timer: nil, lastMinutes: 30, stoppedAt: now.addingTimeInterval(-60), now: now) == .resume(minutes: 30))
        #expect(SleepTimerRules.shake(timer: nil, lastMinutes: 30, stoppedAt: now.addingTimeInterval(-121), now: now) == nil, "too long ago")
        #expect(SleepTimerRules.shake(timer: nil, lastMinutes: 30, stoppedAt: nil, now: now) == nil, "turned off, not stopped by it")
        #expect(SleepTimerRules.shake(timer: .endOfChapter(end: 100), lastMinutes: 30, stoppedAt: nil, now: now) == nil)
        #expect(SleepTimerRules.shake(timer: .endOfEpisode, lastMinutes: nil, stoppedAt: nil, now: now) == nil)
    }

    @Test func findMatchesLinesLikeTheMarksSearch() {
        let sentences = ["今日はＡＢＣの話", "明日の話", "abc です", "話です"].enumerated().map {
            AudioSentence(key: "k", position: $0.offset, start: Double($0.offset), end: Double($0.offset) + 1, text: $0.element)
        }
        let hits = TranscriptFind.hits("abc", in: sentences)
        #expect(hits == [.init(index: 0, range: 3..<6), .init(index: 2, range: 0..<3)])
        #expect(TranscriptFind.hits("話", in: sentences).map(\.index) == [0, 1, 3])
        #expect(TranscriptFind.hits("  ", in: sentences).isEmpty)
        // From the line playing, wrapping round.
        let talk = TranscriptFind.hits("話", in: sentences)
        #expect(TranscriptFind.firstHit(talk, from: 2) == 2)
        #expect(TranscriptFind.firstHit(talk, from: 1) == 1)
        #expect(TranscriptFind.firstHit(talk, from: 4) == 0)
        #expect(TranscriptFind.firstHit(talk, from: nil) == 0)
        #expect(TranscriptFind.firstHit([], from: 1) == nil)
    }
}
