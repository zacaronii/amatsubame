import Foundation
@testable import PlayerKit
import Testing

@Suite struct SubtitleFileTests {
    static let ass = """
    [Script Info]
    Title: Test

    [V4+ Styles]
    Format: Name, Fontname, Fontsize
    Style: Default,Arial,20

    [Events]
    Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
    Dialogue: 0,0:00:01.50,0:00:03.00,Default,,0,0,0,,{\\an8}吾輩は{\\i1}猫{\\i0}である、\\N名前はまだ無い。
    Dialogue: 0,0:00:02.00,0:00:04.00,Sign,,0,0,0,,{\\pos(10,10)}看板
    Dialogue: 0,0:00:05.00,0:00:06.00,OP_JP,,0,0,0,,歌の歌詞
    Dialogue: 0,0:00:07.00,0:00:08.00,Default,,0,0,0,,{\\p1}m 0 0 l 10 10{\\p0}
    Dialogue: 0,0:00:07.00,0:00:07.50,Idol - JP,,0,0,0,fx,{\\pos(1,1)}無
    Dialogue: 0,0:00:07.00,0:00:08.00,Default,,0,0,0,,{\\k20}あ{\\k30}い
    Comment: 0,0:00:09.00,0:00:10.00,Default,,0,0,0,,メモ
    Dialogue: 0,0:01:00.25,0:01:02.00,Default,,0,0,0,,はい、そうです
    """

    /// Kaku's SubRip (Jellyfin episodes transcribed on request): what Miru keeps as "Kaku.srt".
    @Test func kakuSubRip() throws {
        let text = "1\n00:00:09,010 --> 00:00:12,270\nついに、家のお金に手をつけてしまった。\n\n2\n00:00:13,210 --> 00:00:14,650\nもう後には引けない。\n\n3\n01:02:03,400 --> 01:02:05,000\nあ、そこにも。\n"
        let format = try #require(SubtitleFile.format(fileName: "Kaku.srt", text: text))
        let track = SubtitleFile.track(text, format: format)
        #expect(track.cues.map(\.text) == ["ついに、家のお金に手をつけてしまった。", "もう後には引けない。", "あ、そこにも。"])
        #expect(track.cues[0].start == 9.01 && track.cues[0].end == 12.27)
        #expect(track.cues[2].start == 3723.4)
    }

    @Test func assDialogueWithoutDecorations() {
        let track = SubtitleTrack(ass: Self.ass)
        #expect(track.cues.map(\.text) == ["吾輩は猫である、\n名前はまだ無い。", "はい、そうです"])
        #expect(track.cues[0].start == 1.5 && track.cues[0].end == 3)
        #expect(track.cues[1].start == 60.25)
    }

    @Test func bilingualFilesKeepTheJapaneseStyles() {
        let ass = """
        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,0:00:01.00,0:00:02.00,Default - CN,,0,0,0,,我已经不想再拍了
        Dialogue: 0,0:00:01.00,0:00:02.00,Default - JP,,0,0,0,,もうやめたい
        Dialogue: 0,0:00:03.00,0:00:04.00,Screen,,0,0,0,,下集预告
        """
        #expect(SubtitleTrack(ass: ass).cues.map(\.text) == ["もうやめたい"])
        #expect(ASSEvents.isJapaneseStyle("Dialogue_JA") && ASSEvents.isJapaneseStyle("日文") && !ASSEvents.isJapaneseStyle("Jade"))
    }

    @Test func assFieldOrderComesFromFormat() {
        let ass = """
        [Events]
        Format: Start, End, Style, Text
        Dialogue: 0:00:01.00,0:00:02.00,Default,一行目, 続き
        """
        #expect(SubtitleTrack(ass: ass).cues.map(\.text) == ["一行目, 続き"])
    }

    @Test func songLinesDrawnAsCopiesBecomeOneCue() {
        let steps = (0..<7).map { step in
            "Dialogue: 0,0:01:07.\(step)0,0:01:09.00,Default,,0,0,0,,{\\pos(\(step),10)\\t(0,50,\\fscx110)}夢は空の向こう"
        }.joined(separator: "\n")
        let ass = """
        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        \(steps)
        Dialogue: 0,0:01:09.20,0:01:11.00,Default,,0,0,0,,夢は空の向こう
        Dialogue: 0,0:01:08.00,0:01:10.00,Default,,0,0,0,,{\\an8}別の台詞
        Dialogue: 0,0:01:20.00,0:01:22.00,Default,,0,0,0,,夢は空の向こう
        """
        let track = SubtitleTrack(ass: ass)
        #expect(track.cues.map(\.text) == ["夢は空の向こう", "別の台詞", "夢は空の向こう"])
        #expect(track.cues[0].start == 67 && track.cues[0].end == 71)
        #expect(track.cues.map(\.id) == [0, 1, 2])
        #expect(SubtitleTrack(cues: track.cues) == track)
    }

    @Test func detectsFormatsAndEncodings() throws {
        #expect(SubtitleFile.format(fileName: "Ep 01.ja.ASS") == .ass)
        #expect(SubtitleFile.format(fileName: "x.txt", text: "1\n00:00:01,000 --> 00:00:02,000\nあ") == .srt)
        #expect(SubtitleFile.format(fileName: "x.txt", text: "hello") == nil)
        let text = "1\n00:00:01,000 --> 00:00:02,000\n日本語の字幕\n"
        let sjis = try #require(text.data(using: .shiftJIS))
        #expect(SubtitleFile.decode(sjis) == text)
        var utf16 = Data([0xFF, 0xFE])
        utf16.append(try #require(text.data(using: .utf16LittleEndian)))
        #expect(SubtitleFile.decode(utf16)?.contains("日本語の字幕") == true)
        #expect(SubtitleFile.decode(Data(text.utf8)) == text)
    }

    @Test func offsetMovesEveryCue() {
        let track = SubtitleTrack(srt: "1\n00:00:01,000 --> 00:00:02,000\nあ\n\n2\n00:00:05,000 --> 00:00:06,000\nい\n")
        let later = track.offset(by: 1.5)
        #expect(later.cues.map(\.start) == [2.5, 6.5])
        #expect(track.offset(by: -3).cues.map(\.start) == [0, 2])
    }

    @Test func shiftedFilesKeepEverythingElse() {
        let srt = "1\n00:00:01,000 --> 00:00:02,500\n<i>あ</i>\n"
        #expect(SubtitleFile.shifted(srt, format: .srt, by: 0.25) == "1\n00:00:01,250 --> 00:00:02,750\n<i>あ</i>\n")
        let shifted = SubtitleFile.shifted(Self.ass, format: .ass, by: -1)
        #expect(shifted.contains("Dialogue: 0,0:00:00.50,0:00:02.00,Default,,0,0,0,,{\\an8}吾輩は{\\i1}猫{\\i0}である、\\N名前はまだ無い。"))
        #expect(shifted.contains("Dialogue: 0,0:00:59.25,0:01:01.00,Default,,0,0,0,,はい、そうです"))
        #expect(shifted.contains("Style: Default,Arial,20"))
        #expect(shifted.contains("Comment: 0,0:00:09.00"), "only dialogue lines move")
        // The shifted ASS parses to the shifted cues.
        #expect(SubtitleTrack(ass: shifted).cues.map(\.start) == [0.5, 59.25])
    }
}
