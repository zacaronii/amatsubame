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
        let commands: [WatchCommand] = [.togglePlay, .skipBackward, .skipForward, .mark, .markLine(key: "show/ep", line: 3),
                                        .replayLine(key: "show/ep", line: 3), .lookUp(key: "show/ep", line: 3, character: 5),
                                        .addCard(key: "show/ep", line: 3, character: 5), .endLookup, .transcriptPart(id: "show/ep#abc", from: 40)]
        for command in commands {
            #expect(WatchMessages.command(from: WatchMessages.message(command)) == command)
        }
        let reply = WatchReply(message: "Marked 1:40", markedAt: 100, state: state)
        #expect(WatchMessages.reply(from: WatchMessages.message(reply)) == reply)
        let looked = WatchReply(lookup: WatchLookup(start: 2, length: 2, expression: "梅雨", reading: "つゆ", meaning: "rainy season",
                                                    frequency: "4521", lookupCount: 3, isMined: false), state: state)
        #expect(WatchMessages.reply(from: WatchMessages.message(looked)) == looked)
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

    // MARK: Live Text

    let transcript = WatchTranscript(key: "show/ep", fingerprint: "abc", lines: [
        .init(position: 0, start: 1, end: 3, text: "こんにちは。"),
        .init(position: 1, start: 4, end: 8, text: "梅雨の季節ですね。"),
        .init(position: 2, start: 10, end: 12, text: "では、始めましょう。"),
    ])

    @Test func liveTextFollowsTheLinePlaying() {
        #expect(transcript.index(at: 0) == nil)
        #expect(transcript.index(at: 1) == 0)
        // Through the pause after a line, it stays current.
        #expect(transcript.index(at: 9) == 1)
        #expect(transcript.index(at: 600) == 2)
        // From the worked-out position: at 1.5× ten seconds after a sample at 0, it's the third line.
        let playing = WatchNowPlaying(itemId: "show", episodeId: "ep", title: "", subtitle: "", position: 0, duration: 60,
                                      rate: 1.5, isPlaying: true, sampledAt: start)
        #expect(transcript.index(at: playing.position(at: start.addingTimeInterval(7))) == 2)
        #expect(transcript.index(at: playing.position(at: start.addingTimeInterval(3))) == 1)
    }

    @Test func liveTextMessages() throws {
        #expect(try WatchTranscript.decoded(transcript.encoded()) == transcript)
        #expect(transcript.id == "show/ep#abc")
        // A new transcript id is news for the watch.
        var withText = playing()
        withText.transcript = transcript.id
        #expect(!playing().predicts(withText))
        // A line chosen in Live Text marks its start, as a whole line.
        let mark = WatchQueuedMark(line: transcript.lines[1], of: playing(), at: start)
        #expect(mark.position == 4 && mark.wholeLine == true)
        #expect(WatchMessages.queuedMark(from: WatchMessages.userInfo(mark)) == mark)
        // A state saved before Live Text still loads.
        let old = Data(#"{"nowPlaying":null}"#.utf8)
        #expect(try JSONDecoder().decode(WatchState.self, from: old) == WatchState(nowPlaying: nil, liveText: false))
    }

    @Test func aLongTranscriptComesInPartsThatFitAMessage() throws {
        let long = WatchTranscript(key: "show/ep", fingerprint: "abc", lines: (0..<2000).map {
            .init(position: $0, start: Double($0) * 2, end: Double($0) * 2 + 1.5, text: "家でゆっくりしたい、その\($0)番目の理由です。")
        })
        var assembly = WatchTranscriptAssembly(id: long.id)
        var whole: WatchTranscript?
        var parts = 0
        var from: Int? = 0
        while let start = from {
            let part = long.part(from: start)
            // Each reply, state included, stays under WatchConnectivity's 64 KB.
            let reply = WatchReply(transcriptPart: part, state: WatchState(nowPlaying: playing()))
            let message = WatchMessages.message(reply)
            #expect((message["reply"] as? Data)?.count ?? .max < 60_000)
            let received = try #require(WatchMessages.reply(from: message)?.transcriptPart)
            whole = assembly.add(received)
            from = received.next
            parts += 1
        }
        #expect(parts > 1)
        #expect(whole == long)
        // Parts of another transcript or out of order don't count.
        var other = WatchTranscriptAssembly(id: "show/ep#newer")
        #expect(other.add(long.part(from: 0)) == nil && other.next == 0)
        var skipped = WatchTranscriptAssembly(id: long.id)
        #expect(skipped.add(long.part(from: 5)) == nil && skipped.next == 0)
    }

    @Test func theWatchKeepsTheLastFewTranscripts() throws {
        let folder = URL.temporaryDirectory.appending(path: "live-text-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = WatchTranscriptStore(folder: folder)
        try store.save(transcript)
        #expect(store.load(id: "show/ep#abc") == transcript)
        // Another fingerprint isn't this one.
        #expect(store.load(id: "show/ep#newer") == nil)
        for index in 0..<WatchTranscriptStore.kept + 2 {
            try store.save(WatchTranscript(key: "show/\(index)", fingerprint: "f", lines: []))
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path())
        #expect(files.count == WatchTranscriptStore.kept)
    }
}
