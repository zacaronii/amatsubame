import Foundation
@testable import PlayerKit
import Testing

@Suite struct SubtitleTrackTests {
    func fixture() throws -> SubtitleTrack {
        let url = try #require(Bundle.module.url(forResource: "subtitle", withExtension: "srt", subdirectory: "Fixtures"))
        return SubtitleTrack(srt: try String(contentsOf: url, encoding: .utf8))
    }

    @Test func parsesTimesTagsAndLines() throws {
        let track = try fixture()
        #expect(track.cues.map(\.text) == ["吾輩は猫である。", "名前はまだ無い。", "どこで生れたか\nとんと見当がつかぬ。", "（何でも薄暗い）"])
        #expect(track.cues[1].start == 4 && track.cues[1].end == 6.25)
        #expect(track.cues[2].sentence == "どこで生れたかとんと見当がつかぬ。")
    }

    @Test func toleratesCRLFBOMAndJunk() {
        let srt = "\u{FEFF}1\r\n00:00:01.000 --> 00:00:02.000 X1:0\r\n<font color=\"#fff\">一</font>\r\n\r\nnot a cue\r\n\r\n2\r\n01:00.5 --> 01:02.0\r\n二\r\n"
        let track = SubtitleTrack(srt: srt)
        #expect(track.cues.map(\.text) == ["一", "二"])
        #expect(track.cues[1].start == 60.5)
    }

    @Test func dropsInvisibleMarks() {
        let track = SubtitleTrack(srt: "1\n00:01:19,000 --> 00:01:21,000\n\u{200E}\n\u{200E}“マルコ隊長”\u{200B}\n")
        #expect(track.cues.map(\.text) == ["“マルコ隊長”"])
    }

    @Test func lookupByTimeHandlesGapsAndOverlaps() throws {
        let track = try fixture()
        #expect(track.cues(at: 0.5).isEmpty)
        #expect(track.cues(at: 2).map(\.id) == [0])
        #expect(track.cues(at: 3.7).isEmpty)
        #expect(track.currentOrPrevious(at: 3.7)?.id == 0)
        #expect(track.cues(at: 8.7).map(\.id) == [2, 3])
        #expect(track.currentOrPrevious(at: 8.7)?.id == 3)
        #expect(track.cues(at: 10).isEmpty)
    }

    @Test func nextAndPreviousLines() throws {
        let track = try fixture()
        #expect(track.next(after: 2)?.id == 1)
        #expect(track.next(after: 4)?.id == 2)
        #expect(track.next(after: 9) == nil)
        // Early in a line, back goes to the line before; later, to the start of this one.
        #expect(track.previous(before: 4.5)?.id == 0)
        #expect(track.previous(before: 5.5)?.id == 1)
        #expect(track.previous(before: 0.2) == nil)
        #expect(track.previous(before: 1.2)?.id == 0)
    }

    @Test func lineBeforeIgnoresHowFarIntoTheLine() throws {
        let track = try fixture()
        // AirPods triple press: always the line before, however long the press took.
        #expect(track.lineBefore(4.5)?.id == 0)
        #expect(track.lineBefore(5.5)?.id == 0)
        #expect(track.lineBefore(8.7)?.id == 2)
        // The first line has nothing before it, so it plays again.
        #expect(track.lineBefore(2)?.id == 0)
        #expect(track.lineBefore(0.2) == nil)
    }
}
