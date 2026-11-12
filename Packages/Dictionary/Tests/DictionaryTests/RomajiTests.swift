import Dictionary
import Testing

@Suite struct RomajiTests {
    @Test func convertsLikeAnIME() {
        #expect(Romaji.hiragana("taberu") == "たべる")
        #expect(Romaji.hiragana("konnichiha") == "こんにちは")
        #expect(Romaji.hiragana("kitte") == "きって")
        #expect(Romaji.hiragana("shinbun") == "しんぶん")
        #expect(Romaji.hiragana("kan'i") == "かんい")
        #expect(Romaji.hiragana("tokyo") == "ときょ")
        #expect(Romaji.hiragana("toukyou") == "とうきょう")
        #expect(Romaji.hiragana("jisho") == "じしょ")
        #expect(Romaji.hiragana("chotto") == "ちょっと")
        #expect(Romaji.hiragana("tsukue") == "つくえ")
        #expect(Romaji.hiragana("Sushi") == "すし")
        #expect(Romaji.katakana("ra-men") == "ラーメン")
        #expect(Romaji.katakana("ko-hi-") == "コーヒー")
    }

    @Test func leavesOtherTextAlone() {
        #expect(Romaji.hiragana("食べる") == nil)
        #expect(Romaji.hiragana("たべる") == nil)
        #expect(Romaji.hiragana("xyz") == nil)
        #expect(Romaji.hiragana("") == nil)
        #expect(Romaji.hiragana("123") == nil)
    }
}
