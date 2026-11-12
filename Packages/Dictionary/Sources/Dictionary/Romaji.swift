import Foundation

/// Romaji typed into the Dictionary search, as kana (Hepburn and kunrei spellings, as an IME
/// takes them): "taberu" → たべる, "konnichiha" → こんにちは, "kitte" → きって, "ra-men" → らーめん.
public enum Romaji {
    /// The text as hiragana, or nil when it isn't romaji (it has Japanese in it, or letters
    /// that don't make kana, like "xyz").
    public static func hiragana(_ text: String) -> String? {
        let input = text.lowercased().trimmingCharacters(in: .whitespaces)
        guard !input.isEmpty, input.contains(where: \.isLetter),
              input.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.letters.contains($0) || "-'".unicodeScalars.contains($0)) })
        else { return nil }
        let letters = Array(input)
        var output = ""
        var index = 0
        while index < letters.count {
            let rest = letters[index...]
            let character = letters[index]
            if character == "-" {
                output += "ー"
                index += 1
                continue
            }
            if character == "'" {
                index += 1
                continue
            }
            // A doubled consonant is a small っ (not nn).
            if index + 1 < letters.count, character == letters[index + 1], !"aeioun".contains(character) {
                output += "っ"
                index += 1
                continue
            }
            // ん: "nn", "n'", or n before a consonant or at the end.
            if character == "n" {
                let next = index + 1 < letters.count ? letters[index + 1] : nil
                if next == "n" {
                    // "nn" is ん, but in "konnichiha" the second n starts に.
                    let after = index + 2 < letters.count ? letters[index + 2] : nil
                    output += "ん"
                    index += after.map { "aeiouy".contains($0) } == true ? 1 : 2
                    continue
                }
                if next == nil || !"aeiouy".contains(next!) {
                    output += "ん"
                    index += 1
                    continue
                }
            }
            var matched = false
            for length in stride(from: 3, through: 1, by: -1) where rest.count >= length {
                let piece = String(rest.prefix(length))
                if let kana = table[piece] {
                    output += kana
                    index += length
                    matched = true
                    break
                }
            }
            if !matched { return nil }
        }
        return output
    }

    /// The same as katakana (loanwords: "ko-hi-" → コーヒー).
    public static func katakana(_ text: String) -> String? {
        hiragana(text).map { hiragana in
            String(String.UnicodeScalarView(hiragana.unicodeScalars.map { scalar in
                (0x3041...0x3096).contains(scalar.value) ? Unicode.Scalar(scalar.value + 0x60)! : scalar
            }))
        }
    }

    static let table: [String: String] = {
        var table: [String: String] = [
            "a": "あ", "i": "い", "u": "う", "e": "え", "o": "お",
            "ka": "か", "ki": "き", "ku": "く", "ke": "け", "ko": "こ",
            "ga": "が", "gi": "ぎ", "gu": "ぐ", "ge": "げ", "go": "ご",
            "sa": "さ", "shi": "し", "si": "し", "su": "す", "se": "せ", "so": "そ",
            "za": "ざ", "ji": "じ", "zi": "じ", "zu": "ず", "ze": "ぜ", "zo": "ぞ",
            "ta": "た", "chi": "ち", "ti": "ち", "tsu": "つ", "tu": "つ", "te": "て", "to": "と",
            "da": "だ", "di": "ぢ", "du": "づ", "de": "で", "do": "ど",
            "na": "な", "ni": "に", "nu": "ぬ", "ne": "ね", "no": "の",
            "ha": "は", "hi": "ひ", "fu": "ふ", "hu": "ふ", "he": "へ", "ho": "ほ",
            "ba": "ば", "bi": "び", "bu": "ぶ", "be": "べ", "bo": "ぼ",
            "pa": "ぱ", "pi": "ぴ", "pu": "ぷ", "pe": "ぺ", "po": "ぽ",
            "ma": "ま", "mi": "み", "mu": "む", "me": "め", "mo": "も",
            "ya": "や", "yu": "ゆ", "yo": "よ",
            "ra": "ら", "ri": "り", "ru": "る", "re": "れ", "ro": "ろ",
            "wa": "わ", "wi": "うぃ", "we": "うぇ", "wo": "を",
            "fa": "ふぁ", "fi": "ふぃ", "fe": "ふぇ", "fo": "ふぉ",
            "va": "ゔぁ", "vi": "ゔぃ", "vu": "ゔ", "ve": "ゔぇ", "vo": "ゔぉ",
            "she": "しぇ", "je": "じぇ", "che": "ちぇ", "thi": "てぃ", "dhi": "でぃ", "tsa": "つぁ",
            "xa": "ぁ", "xi": "ぃ", "xu": "ぅ", "xe": "ぇ", "xo": "ぉ", "la": "ぁ", "li": "ぃ", "lu": "ぅ", "le": "ぇ", "lo": "ぉ",
            "xya": "ゃ", "xyu": "ゅ", "xyo": "ょ", "lya": "ゃ", "lyu": "ゅ", "lyo": "ょ", "xtu": "っ", "ltu": "っ",
        ]
        // Contracted sounds: kya, sha/sya, cha/tya/cya, ja/jya/zya, nya, hya, mya, rya, gya, bya, pya, dya.
        let rows: [(String, String)] = [("k", "き"), ("g", "ぎ"), ("n", "に"), ("h", "ひ"), ("b", "び"), ("p", "ぴ"),
                                         ("m", "み"), ("r", "り"), ("s", "し"), ("z", "じ"), ("t", "ち"), ("c", "ち"), ("d", "ぢ")]
        for (consonant, kana) in rows {
            table[consonant + "ya"] = kana + "ゃ"
            table[consonant + "yu"] = kana + "ゅ"
            table[consonant + "yo"] = kana + "ょ"
        }
        for (prefix, kana) in [("sh", "し"), ("ch", "ち"), ("j", "じ"), ("jy", "じ")] {
            table[prefix + "a"] = kana + "ゃ"
            table[prefix + "u"] = kana + "ゅ"
            table[prefix + "o"] = kana + "ょ"
        }
        return table
    }()
}
