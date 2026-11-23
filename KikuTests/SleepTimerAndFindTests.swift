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

    /// Only a timer of minutes that stopped playback itself leaves a shake able to bring it back:
    /// not End of Chapter or End of Episode (even with an earlier timer of minutes), and not one
    /// running out after a pause by hand.
    @Test func onlyAMinutesTimerThatStoppedPlaybackArmsTheResume() {
        #expect(SleepTimerRules.armsResume(stopping: .minutes(15, ends: now), wasPlaying: true))
        #expect(!SleepTimerRules.armsResume(stopping: .minutes(15, ends: now), wasPlaying: false), "already paused by hand")
        #expect(!SleepTimerRules.armsResume(stopping: .endOfChapter(end: 100), wasPlaying: true))
        #expect(!SleepTimerRules.armsResume(stopping: .endOfEpisode, wasPlaying: true))
    }

    @Test func threeJoltsInASecondAreAShake() {
        var pattern = ShakePattern()
        let t = { (seconds: Double) in self.now.addingTimeInterval(seconds) }
        do { let shook = pattern.registers(g: 1.1, at: t(0)); #expect(!shook, "at rest") }
        do { let shook = pattern.registers(g: 3, at: t(0)); #expect(!shook) }
        do { let shook = pattern.registers(g: 3, at: t(0.3)); #expect(!shook, "two: not yet") }
        do { let shook = pattern.registers(g: 3, at: t(0.6)); #expect(shook, "three within a second") }
        // Nothing for two seconds after one.
        do { let shook = pattern.registers(g: 3, at: t(1.0)); #expect(!shook) }
        do { let shook = pattern.registers(g: 3, at: t(1.3)); #expect(!shook) }
        do { let shook = pattern.registers(g: 3, at: t(1.6)); #expect(!shook, "still within two seconds of the last shake") }
        do { let shook = pattern.registers(g: 3, at: t(2.7)); #expect(!shook) }
        do { let shook = pattern.registers(g: 3, at: t(3.0)); #expect(!shook) }
        do { let shook = pattern.registers(g: 3, at: t(3.3)); #expect(shook, "after the rest, three again") }
    }

    @Test func joltsSpreadOutOrReadTwiceAreNotAShake() {
        var spread = ShakePattern()
        let t = { (seconds: Double) in self.now.addingTimeInterval(seconds) }
        do { let shook = spread.registers(g: 3, at: t(0)); #expect(!shook) }
        do { let shook = spread.registers(g: 3, at: t(0.6)); #expect(!shook) }
        do { let shook = spread.registers(g: 3, at: t(1.3)); #expect(!shook, "the first is over a second old") }
        var close = ShakePattern()
        // One jolt read over several samples counts once: three samples 0.05 s apart, then one more.
        do { let shook = close.registers(g: 3, at: t(0)); #expect(!shook) }
        do { let shook = close.registers(g: 3, at: t(0.05)); #expect(!shook) }
        do { let shook = close.registers(g: 3, at: t(0.1)); #expect(!shook) }
        do { let shook = close.registers(g: 3, at: t(0.4)); #expect(!shook, "two jolts so far") }
        do { let shook = close.registers(g: 1.5, at: t(0.5)); #expect(!shook, "under 1.3 g off rest") }
        do { let shook = close.registers(g: 2.5, at: t(0.7)); #expect(shook) }
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

@MainActor @Suite struct MarkNoteSearchTests {
    @Test func notesAreFoundLikeLines() {
        #expect(MarksModel.noteMatches("駅の場面、後で調べる", "場面"))
        #expect(MarksModel.noteMatches("Look up LATER", "later"), "any case")
        #expect(!MarksModel.noteMatches("駅の場面", "電車"))
        #expect(!MarksModel.noteMatches(nil, "場面"))
        #expect(!MarksModel.noteMatches("駅の場面", "  "))
    }
}
