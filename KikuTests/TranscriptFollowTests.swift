import AudiobookshelfKit
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

    /// Playing again after a pause starts the cut-off line over.
    @Test func resumingStartsTheLineAgain() {
        #expect(TranscriptFollow.resumeTarget(at: 14.5, in: sentences, pausedFor: 10) == 13)
        #expect(TranscriptFollow.resumeTarget(at: 14.5, in: sentences, pausedFor: 0.5) == nil, "a moment's pause")
        #expect(TranscriptFollow.resumeTarget(at: 18, in: sentences, pausedFor: 10) == nil, "in the gap after the line")
        #expect(TranscriptFollow.resumeTarget(at: 13.1, in: sentences, pausedFor: 10) == nil, "already at its start")
        #expect(TranscriptFollow.resumeTarget(at: 5, in: sentences, pausedFor: 10) == nil, "before the first line")
        #expect(TranscriptFollow.resumeTarget(at: 40, in: [line(0, 10, 60)], pausedFor: 10) == nil, "a very long line: not that far back")
    }

    /// Play the Next Episode: the show's next by date that isn't finished.
    @Test func theNextEpisodeOfTheShow() throws {
        func episode(_ id: String, _ published: Double?) throws -> AudiobookshelfEpisode {
            let date = published.map { #", "publishedAt": \#($0)"# } ?? ""
            return try JSONDecoder().decode(AudiobookshelfEpisode.self, from: Data(#"{"id": "\#(id)", "libraryItemId": "show", "title": "\#(id)"\#(date)}"#.utf8))
        }
        let episodes = [try episode("e4", 400), try episode("e1", 100), try episode("e3", 300), try episode("e2", 200), try episode("undated", nil)]
        #expect(PodcastLibrary.episode(after: episodes[3], in: episodes, finished: { _ in false })?.id == "e3")
        #expect(PodcastLibrary.episode(after: episodes[3], in: episodes, finished: { $0.id == "e3" })?.id == "e4", "past one already heard")
        #expect(PodcastLibrary.episode(after: episodes[0], in: episodes, finished: { _ in false }) == nil, "nothing after the newest")
        #expect(PodcastLibrary.episode(after: episodes[4], in: episodes, finished: { _ in false }) == nil, "no date, no order")
    }

    /// Pause After Each Line and Repeat the Line act as the line that was playing ends.
    @Test func theLineThatJustEnded() {
        #expect(TranscriptFollow.lineJustEnded(at: 11.5, previous: 0, in: sentences) == nil, "still playing")
        #expect(TranscriptFollow.lineJustEnded(at: 12.1, previous: 0, in: sentences) == 0)
        #expect(TranscriptFollow.lineJustEnded(at: 16.2, previous: 1, in: sentences) == 1)
        #expect(TranscriptFollow.lineJustEnded(at: 19.5, previous: 1, in: sentences) == nil, "long past it: a jump, not its end")
        #expect(TranscriptFollow.lineJustEnded(at: 12.1, previous: nil, in: sentences) == nil)
    }

    /// A show's own speed and skips are kept, and forgotten when they say nothing.
    @Test func aShowsOwnPlaybackSettings() throws {
        let database = try AppDatabase.inMemory()
        #expect(ShowListenSetting.load(database, itemId: "show").speed == nil)
        var setting = ShowListenSetting(itemId: "show", speed: 0.9, skipStart: 15, skipEnd: 30)
        try setting.save(database)
        #expect(ShowListenSetting.load(database, itemId: "show") == setting)
        #expect(ShowListenSetting.load(database, itemId: "other").skipStart == 0)
        setting = ShowListenSetting(itemId: "show")
        try setting.save(database)
        #expect(ShowListenSetting.load(database, itemId: "show") == ShowListenSetting(itemId: "show"), "nothing left to keep")
        #expect(ListenSettings.load(database).transcriptScale == 1 && !ListenSettings.load(database).pausesAfterLines)
    }
}
