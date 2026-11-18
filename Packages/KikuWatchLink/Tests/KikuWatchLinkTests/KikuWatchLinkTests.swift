import Foundation
@testable import KikuWatchLink
import Testing

@Suite struct KikuWatchLinkTests {
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    func playing(_ position: Double = 100, rate: Double = 1, isPlaying: Bool = true, chapter: String? = nil) -> WatchNowPlaying {
        WatchNowPlaying(itemId: "show", episodeId: "ep", title: "#48 梅雨の楽しみ方", subtitle: "週末のんびり雑談室", chapter: chapter,
                        position: position, duration: 600, rate: rate, isPlaying: isPlaying, sampledAt: start,
                        artwork: Data([0xFF, 0xD8]))
    }

    @Test func positionMovesAtTheRateWhilePlaying() {
        #expect(playing().position(at: start.addingTimeInterval(10)) == 110)
        #expect(playing(rate: 1.5).position(at: start.addingTimeInterval(10)) == 115)
        // Paused: it stays.
        #expect(playing(isPlaying: false).position(at: start.addingTimeInterval(10)) == 100)
        // Never past the end, and never back before the sample.
        #expect(playing(590).position(at: start.addingTimeInterval(60)) == 600)
        #expect(playing().position(at: start.addingTimeInterval(-5)) == 100)
        #expect(playing(300).fraction(at: start) == 0.5)
    }

    @Test func aStateThatWasPredictedIsNotSentAgain() {
        let sent = playing()
        var later = playing(130)
        later.sampledAt = start.addingTimeInterval(30)
        #expect(sent.predicts(later))
        // A seek, a pause, another speed or chapter are news.
        var seeked = later
        seeked.position = 200
        #expect(!sent.predicts(seeked))
        var paused = later
        paused.isPlaying = false
        #expect(!sent.predicts(paused))
        var faster = later
        faster.rate = 1.25
        #expect(!sent.predicts(faster))
        var chapter = later
        chapter.chapter = "第二章"
        #expect(!sent.predicts(chapter))
    }

    @Test func messagesRoundTrip() {
        let state = WatchState(nowPlaying: playing(chapter: "第一章"))
        #expect(WatchMessages.state(from: WatchMessages.context(state)) == state)
        #expect(WatchMessages.state(from: WatchMessages.context(WatchState(nowPlaying: nil))) == WatchState(nowPlaying: nil))
        for command in [WatchCommand.togglePlay, .skipBackward, .skipForward, .mark] {
            #expect(WatchMessages.command(from: WatchMessages.message(command)) == command)
        }
        let reply = WatchReply(message: "Marked 1:40", markedAt: 100, state: state)
        #expect(WatchMessages.reply(from: WatchMessages.message(reply)) == reply)
        let mark = WatchQueuedMark(playing(), at: start.addingTimeInterval(12))
        #expect(mark.position == 112)
        #expect(WatchMessages.queuedMark(from: WatchMessages.userInfo(mark)) == mark)
        // Other dictionaries aren't mistaken for these.
        #expect(WatchMessages.command(from: ["state": Data()]) == nil)
        #expect(WatchMessages.state(from: [:]) == nil)
    }

    @Test func keysMatchKikusProgressKeys() {
        #expect(playing().key == "show/ep")
        var book = playing()
        book.episodeId = ""
        #expect(book.key == "show")
    }

    @Test func clockText() {
        #expect(52.9.watchClock == "0:52")
        #expect(801.0.watchClock == "13:21")
        #expect(3725.0.watchClock == "1:02:05")
    }
}
