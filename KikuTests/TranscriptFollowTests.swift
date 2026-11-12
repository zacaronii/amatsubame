import Core
import Foundation
@testable import Kiku
import Testing

@MainActor @Suite struct TranscriptFollowTests {
    let sentences = [(10.0, 12.0), (13.0, 16.0), (20.0, 25.0)].enumerated().map { index, times in
        AudioSentence(key: "k", position: index, start: times.0, end: times.1, text: "\(index)")
    }

    func line(_ position: Int, _ start: Double, _ end: Double) -> AudioSentence {
        AudioSentence(key: "k", position: position, start: start, end: end, text: "\(position)")
    }

    @Test func currentLineStaysThroughThePauseAfterIt() {
        #expect(TranscriptFollow.index(at: 5, in: sentences) == nil)
        #expect(TranscriptFollow.index(at: 10, in: sentences) == 0)
        #expect(TranscriptFollow.index(at: 12.5, in: sentences) == 0)
        #expect(TranscriptFollow.index(at: 18, in: sentences) == 1)
        #expect(TranscriptFollow.index(at: 99, in: sentences) == 2)
        #expect(TranscriptFollow.index(at: 1, in: []) == nil)
    }

    @Test func previousRestartsThenGoesBack() {
        #expect(TranscriptFollow.previousTarget(from: 21, in: sentences) == 13)
        #expect(TranscriptFollow.previousTarget(from: 23, in: sentences) == 20)
        #expect(TranscriptFollow.previousTarget(from: 10.5, in: sentences) == 10)
        #expect(TranscriptFollow.previousTarget(from: 3, in: sentences) == 0)
    }

    @Test func nextGoesToTheNextStart() {
        #expect(TranscriptFollow.nextTarget(from: 3, in: sentences) == 10)
        #expect(TranscriptFollow.nextTarget(from: 13, in: sentences) == 20)
        #expect(TranscriptFollow.nextTarget(from: 21, in: sentences) == nil)
    }

    /// Lines at 0–4, 5–9 and 10–20 s.
    @Test func markPointsAtTheLineThatJustEnded() {
        let lines = [line(0, 0, 4), line(1, 5, 9), line(2, 10, 20)]
        #expect(TranscriptFollow.markedIndex(at: 11, in: lines) == 1)
        #expect(TranscriptFollow.markedIndex(at: 9.5, in: lines) == 1)
        #expect(TranscriptFollow.markedIndex(at: 16, in: lines) == 2)
        #expect(TranscriptFollow.markedIndex(at: 1, in: lines) == 0)
        #expect(TranscriptFollow.markedIndex(at: 3, in: []) == nil)
        #expect(TranscriptFollow.markWindow(at: 11, in: lines)?.lines.map(\.position) == [0, 1, 2])
        #expect(TranscriptFollow.markWindow(at: 1, in: lines)?.lines.map(\.position) == [0, 1])
    }

    /// The player's button marks the line playing, even just after it started.
    @Test func playerMarksTakeTheLinePlaying() {
        let lines = [line(0, 0, 4), line(1, 5, 9), line(2, 10, 20)]
        #expect(TranscriptFollow.markedIndex(at: 11, in: lines, guessesEarlier: false) == 2)
        #expect(TranscriptFollow.markWindow(at: 11, in: lines, guessesEarlier: false)?.marked == 2)
    }

    @Test func newEpisodesAfterTheNewestStarted() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let day: TimeInterval = 86400
        let episodes: [(published: Date?, started: Bool)] = [
            (now.addingTimeInterval(-1 * day), false), (now.addingTimeInterval(-3 * day), false),
            (now.addingTimeInterval(-5 * day), true), (now.addingTimeInterval(-9 * day), false),
        ]
        #expect(EpisodeNews.newCount(episodes: episodes, now: now) == 2)
        // Never played: the last two weeks.
        let fresh = episodes.map { (published: $0.published, started: false) } + [(now.addingTimeInterval(-30 * day), false)]
        #expect(EpisodeNews.newCount(episodes: fresh, now: now) == 4)
        #expect(EpisodeNews.newCount(episodes: [(now, true)], now: now) == 0)
    }

    @Test func clockAndLength() {
        #expect(789.4.clockText == "13:09")
        #expect(3735.0.clockText == "1:02:15")
        #expect(1380.0.lengthText == "23 min")
        #expect(3840.0.lengthText == "1 h 4 min")
        #expect(20.0.lengthText == "1 min")
    }
}
