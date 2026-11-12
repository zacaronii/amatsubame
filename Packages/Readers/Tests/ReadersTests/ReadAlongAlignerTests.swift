import Foundation
@testable import Readers
import Testing

@Suite struct ReadAlongAlignerTests {
    /// A narration of `text`, two characters a word, a quarter second a character, from `start`.
    static func spoken(_ text: String, from start: Double) -> [TimedWord] {
        let characters = Array(text)
        return stride(from: 0, to: characters.count, by: 2).map { index in
            let piece = String(characters[index..<min(index + 2, characters.count)])
            let at = start + Double(index) * 0.25
            return TimedWord(text: piece, start: at, end: at + Double(piece.count) * 0.25)
        }
    }

    let book = [
        BookTextRun(section: 0, run: 0, text: "目次"),
        BookTextRun(section: 0, run: 1, text: "第一章　夢　第二章　出会い"),
        BookTextRun(section: 1, run: 0, text: "朝、窓を開けると雨の匂いがした。そういう日が、時々ある。"),
        BookTextRun(section: 1, run: 1, text: "昨日の約束は、いつも思い出せない。ただ、何か大切なことを忘れたという気持ちだけが、昼を過ぎても長く残る。"),
        BookTextRun(section: 2, run: 0, text: "あとがき　この本を読んでくださった皆さまに感謝します。"),
    ]

    @Test func narratedSentencesGetTheirTimesAndTheRestIsSkipped() {
        // The narrator adds a title, mishears one word (思い出せない → おもいだせない), and
        // doesn't read the contents or the afterword.
        let narration = "小説、森の灯り。山田空。" + "朝、窓を開けると雨の匂いがした。そういう日が、時々ある。"
            + "昨日の約束は、いつもおもいだせない。ただ、何か大切なことを忘れたという気持ちだけが、昼を過ぎても長く残る。"
        let cues = ReadAlongAligner.align(runs: book, words: Self.spoken(narration, from: 10))
        #expect(cues.map(\.section).allSatisfy { $0 == 1 }, "contents and afterword aren't narrated")
        #expect(cues.count == 4)
        let first = cues[0]
        #expect(first.run == 0 && first.offset == 0 && first.length == "朝、窓を開けると雨の匂いがした。".utf16.count)
        // "朝" is the 13th character spoken (after the 12-character title): 10 + 12 × 0.25 = 13.
        #expect(abs(first.start - 13) < 0.3)
        #expect(cues.map(\.start) == cues.map(\.start).sorted())
        let misheard = cues[2]
        #expect(misheard.run == 1 && misheard.score < 1 && misheard.score > 0.4, "timed by its neighbours")
        #expect(cues[3].end > cues[3].start && cues[3].score == 1)
    }

    @Test func nothingMatchesNothing() {
        #expect(ReadAlongAligner.align(runs: book, words: Self.spoken("まったく別の話をしています。", from: 0)).isEmpty)
        #expect(ReadAlongAligner.align(runs: [], words: Self.spoken("朝", from: 0)).isEmpty)
    }

    @Test func kanaAndWidthAreFolded() {
        #expect(ReadAlongAligner.normalised("カタカナ、ＡＢＣ１２") == ReadAlongAligner.normalised("かたかなabc12"))
        #expect(ReadAlongAligner.normalised("「ねえ……」 ") == ReadAlongAligner.normalised("ねえ"))
    }
}

@Suite struct ReadAlongCuesTests {
    let cues = ReadAlongCues([
        ReadAlongCue(section: 1, run: 0, offset: 0, length: 10, start: 5, end: 8, score: 1),
        ReadAlongCue(section: 1, run: 0, offset: 10, length: 6, start: 8.5, end: 10, score: 1),
        ReadAlongCue(section: 1, run: 2, offset: 0, length: 4, start: 12, end: 13, score: 1),
        ReadAlongCue(section: 3, run: 1, offset: 0, length: 4, start: 20, end: 21, score: 1),
    ])

    @Test func byTimeTheLastStartedStays() {
        #expect(cues.index(at: 1) == nil)
        #expect(cues.index(at: 5) == 0 && cues.index(at: 8.4) == 0 && cues.index(at: 11) == 1 && cues.index(at: 99) == 3)
    }

    @Test func byPlaceInTheText() {
        #expect(cues.index(section: 1, run: 0, offset: 12) == 1)
        #expect(cues.index(section: 1, run: 1, offset: 0) == 2, "an unnarrated run: the next cue")
        #expect(cues.firstIndex(section: 2) == 3, "a section without cues: the next one that has some")
        #expect(cues.firstIndex(section: 1, fromRun: 1) == 2)
        #expect(ReadAlongCues(data: cues.data) == cues)
    }

    /// From a page: the sentence it starts in, or the last matched one before an unmatched page.
    @Test func listeningStartsAtOrBeforeThePage() {
        #expect(cues.startIndex(section: 1, run: 0, offset: 12) == 1)
        #expect(cues.startIndex(section: 1, run: 1, offset: 5) == 1, "an unmatched run: the sentence before it")
        #expect(cues.startIndex(section: 2, run: 0, offset: 0) == 2)
        #expect(cues.startIndex(section: 0, run: 0, offset: 0) == 0, "before every cue: the first")
    }

    /// From a page with its end known: the first sentence on it, else as above.
    @Test func listeningStartsOnThePage() {
        #expect(cues.startIndex(section: 1, run: 0, offset: 12, nextPage: (2, 0)) == 1, "the sentence the page starts in")
        #expect(cues.startIndex(section: 1, run: 0, offset: 16, nextPage: (3, 0)) == 2, "the first one on the page")
        #expect(cues.startIndex(section: 1, run: 1, offset: 0, nextPage: (1, 9)) == 1, "none on the page: the one before")
        #expect(cues.startIndex(section: 1, run: 1, offset: 0, nextPage: nil) == 2, "the section's last page: up to its end")
    }
}
