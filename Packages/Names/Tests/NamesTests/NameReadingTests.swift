@testable import Names
import Testing

/// Readings from AniList's romaji: its "ou/uu" spelling, Hepburn's marks, and the spellings
/// that can't be settled without JMnedict.
@Suite struct NameReadingTests {
    @Test(arguments: [
        ("Gotou", "ごとう", false), ("Yuuki", "ゆうき", false), ("Yūki", "ゆうき", false), ("Konno", "こんの", false),
        ("Homma", "ほんま", false), ("Namba", "なんば", false), ("Shin'ichi", "しんいち", false), ("Kyouko", "きょうこ", false),
        ("Ōno", "おうの", true), ("Ohno", "おうの", true), ("Satoh", "さとう", true),
    ])
    func romajiAsKana(romaji: String, kana: String, unsure: Bool) throws {
        let converted = try #require(NameRomaji.hiragana(romaji))
        #expect(converted.kana == kana && converted.unsure == unsure)
    }

    @Test func spellingsCompareAsOne() {
        #expect(NameRomaji.key("Yūki") == NameRomaji.key("Yuuki"))
        #expect(NameRomaji.key("Ōno") == NameRomaji.key("Oono"))
        #expect(NameRomaji.key("Homma") == NameRomaji.key("Honma"))
        #expect(NameRomaji.key("Shin'ichi") == NameRomaji.key("Shinichi"))
        #expect(NameRomaji.romaji(fromKana: "しんいち") == "shinichi")
        #expect(NameRomaji.romaji(fromKana: "きょうこ") == "kyouko")
        #expect(NameRomaji.romaji(fromKana: "まっちゃ") == "matcha")
        #expect(NameRomaji.romaji(fromKana: "ジョー") == "joo")
    }

    func character(_ native: String?, first: String?, last: String?, alternative: [String] = []) -> AniListCharacter {
        AniListCharacter(id: 1, role: .main, native: native, full: [first, last].compactMap(\.self).joined(separator: " "),
                         first: first, last: last, alternative: alternative)
    }

    func forms(_ character: AniListCharacter) async -> [String] {
        await NameForms.forms(of: character, readings: FakeReadings()).map { "\($0.term)|\($0.reading ?? "-")|\($0.part.rawValue)" }
    }

    /// A space splits family and given; JMnedict's reading that spells the romaji wins (架空
    /// has two).
    @Test func spacedName() async {
        #expect(await forms(character("架空 太郎", first: "Tarou", last: "Kakuu"))
            == ["架空太郎|かくうたろう|full", "架空|かくう|family", "太郎|たろう|given"])
    }

    /// No space: split where both halves are confirmed (JMnedict, or kana spelling the romaji).
    @Test func spacelessNameSplitsWhenSure() async {
        #expect(await forms(character("夢見ひかり", first: "Hikari", last: "Yumemi"))
            == ["夢見ひかり|ゆめみひかり|full", "夢見|ゆめみ|family", "ひかり|ひかり|given"])
    }

    /// Neither half known: the whole name only, read from the romaji.
    @Test func spacelessNameUnsureStaysWhole() async {
        #expect(await forms(character("謎野謎子", first: "Nazoko", last: "Nazono")) == ["謎野謎子|なぞのなぞこ|full"])
    }

    /// ō could be おう or おお: JMnedict settles 大石; the given name reads itself.
    @Test func unsureRomajiNeedsJMnedict() async {
        #expect(await forms(character("大石 森", first: "Mori", last: "Ōishi"))
            == ["大石森|おおいしもり|full", "大石|おおいし|family", "森|もり|given"])
        #expect(await forms(character("大野 森", first: "Mori", last: "Ōno"))
            == ["大野森|-|full", "大野|-|family", "森|もり|given"])
    }

    @Test func katakanaWithADot() async {
        #expect(await forms(character("ミラ・ソーン", first: "Mira", last: "Thorn"))
            == ["ミラソーン|みらそーん|full", "ミラ・ソーン|みらそーん|full", "ミラ|みら|part", "ソーン|そーん|part"])
    }

    @Test func descriptionsAndAliases() async {
        #expect(await forms(character("王様", first: "Ou-sama", last: nil)) == [])
        #expect(await forms(character(nil, first: "Nobody", last: nil)) == [])
        #expect(await forms(character("架空 太郎", first: "Tarou", last: "Kakuu", alternative: ["Taro-kun (たろくん)", "The Boy"])).last
            == "たろくん|たろくん|alias")
    }
}
