@testable import Readers
import Testing

/// Look Up on Hover on a manga page (Mac): which character the pointer rests on looks a word up.
@Suite struct MangaHoverLookupTests {
    @Test func aWordCharacterLooksUp() {
        #expect(MangaReaderModel.hoverLooksUp("今日はいい天気", at: 2, marked: nil, controlsShowing: false))
    }

    @Test func punctuationSpacesAndThePastEndDoNot() {
        #expect(!MangaReaderModel.hoverLooksUp("ダメ！そんな", at: 2, marked: nil, controlsShowing: false))
        #expect(!MangaReaderModel.hoverLooksUp("あ い", at: 1, marked: nil, controlsShowing: false))
        #expect(!MangaReaderModel.hoverLooksUp("…", at: 0, marked: nil, controlsShowing: false))
        #expect(!MangaReaderModel.hoverLooksUp("あい", at: 5, marked: nil, controlsShowing: false))
    }

    @Test func theWordAlreadyMarkedStays() {
        #expect(!MangaReaderModel.hoverLooksUp("今日はいい天気", at: 1, marked: 0..<2, controlsShowing: false), "still inside it")
        #expect(MangaReaderModel.hoverLooksUp("今日はいい天気", at: 5, marked: 0..<2, controlsShowing: false), "another word")
    }

    @Test func notWhileTheControlsShow() {
        #expect(!MangaReaderModel.hoverLooksUp("今日", at: 0, marked: nil, controlsShowing: true))
    }
}
