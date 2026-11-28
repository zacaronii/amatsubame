import Dictionary
import Foundation

/// Where a name's readings can be checked: JMnedict's readings for the exact spelling.
public protocol NameReadingSource: Sendable {
    func readings(of expression: String) async -> [String]
}

/// No checking (JMnedict isn't installed).
public struct NoNameReadings: NameReadingSource {
    public init() {}
    public func readings(of expression: String) async -> [String] { [] }
}

/// A name's kana from AniList's romaji, which is all AniList has for a reading. Its romaji is
/// mostly "ou/uu" style (Gotou, Yuuki), sometimes Hepburn (Yūki, Ōno, Homma). A spelling the
/// romaji can't settle (ō: おう or おお? oh: おう or おお?) gives no reading unless JMnedict has
/// the same name with a reading that agrees; nothing is guessed.
public enum NameRomaji {
    /// The romaji as kana, and whether it's unsure (two readings are possible).
    public static func hiragana(_ romaji: String) -> (kana: String, unsure: Bool)? {
        var unsure = false
        var text = romaji.lowercased().precomposedStringWithCanonicalMapping
        // Long vowels: ā ī ū ē (and ^ forms) are doubled; ō is おう in most names, おお in some
        // (Ōno 大野), so it's unsure.
        for (marked, plain) in [("ā", "aa"), ("â", "aa"), ("ī", "ii"), ("î", "ii"), ("ū", "uu"), ("û", "uu"), ("ē", "ee"), ("ê", "ee")] {
            text = text.replacingOccurrences(of: marked, with: plain)
        }
        if text.contains("ō") || text.contains("ô") {
            unsure = true
            text = text.replacingOccurrences(of: "ō", with: "ou").replacingOccurrences(of: "ô", with: "ou")
        }
        // "oh" before a consonant or at the end (Ohno, Satoh): おお or おう.
        if text.range(of: "oh(?=[^aeiouy]|$)", options: .regularExpression) != nil {
            unsure = true
            text = text.replacingOccurrences(of: "oh(?=[^aeiouy]|$)", with: "ou", options: .regularExpression)
        }
        // Hepburn's m before b, p, m is ん (Homma, Namba).
        text = text.replacingOccurrences(of: "m(?=[bpm])", with: "n'", options: .regularExpression)
        text = text.replacingOccurrences(of: "[\\s-]", with: "", options: .regularExpression)
        guard let kana = Romaji.hiragana(text) else { return nil }
        return (kana, unsure)
    }

    /// The romaji as one comparable spelling: Hepburn, long vowels as "ou/uu" doubles, without
    /// apostrophes. Two readings that come out the same are the same name.
    public static func key(_ romaji: String) -> String {
        var text = romaji.lowercased().precomposedStringWithCanonicalMapping
        for (marked, plain) in [("ā", "aa"), ("â", "aa"), ("ī", "ii"), ("î", "ii"), ("ū", "uu"), ("û", "uu"), ("ē", "ee"), ("ê", "ee"),
                                ("ō", "ou"), ("ô", "ou")] {
            text = text.replacingOccurrences(of: marked, with: plain)
        }
        text = text.replacingOccurrences(of: "[^a-z]", with: "", options: .regularExpression)
        let rules: [(String, String)] = [
            ("oh(?=[^aeiouy]|$)", "ou"), ("oo", "ou"), ("m(?=[bpm])", "n"),
            ("(?<![sc])hu", "fu"), ("si", "shi"), ("ti", "chi"), ("tu", "tsu"), ("zi", "ji"), ("di", "ji"), ("du", "zu"),
            ("sy([auo])", "sh$1"), ("ty([auo])", "ch$1"), ("cy([auo])", "ch$1"), ("[zj]y([auo])", "j$1"),
        ]
        for (pattern, replacement) in rules {
            text = text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return text
    }

    /// `key` with long vowels shortened (Yuki for ゆうき), for a looser second check.
    static func shortKey(_ romaji: String) -> String {
        var text = key(romaji)
        for (long, short) in [("ou", "o"), ("uu", "u"), ("aa", "a"), ("ii", "i"), ("ee", "e"), ("ei", "e")] {
            text = text.replacingOccurrences(of: long, with: short)
        }
        return text
    }

    /// Kana as Hepburn romaji (for comparing with AniList's spelling).
    public static func romaji(fromKana kana: String) -> String {
        let characters = Array(NameKana.hiragana(kana))
        var output = ""
        var index = 0
        var doubleNext = false
        while index < characters.count {
            let character = characters[index]
            if character == "っ" {
                doubleNext = true
                index += 1
                continue
            }
            if character == "ー", let last = output.last {
                output.append(last)
                index += 1
                continue
            }
            var piece: String?
            if index + 1 < characters.count, let pair = inverse[String(characters[index...index + 1])] {
                piece = pair
                index += 2
            } else {
                piece = inverse[String(character)] ?? String(character)
                index += 1
            }
            if doubleNext, let first = piece?.first {
                output.append(first == "c" ? "t" : first)
                doubleNext = false
            }
            output += piece ?? ""
        }
        return output
    }

    /// Kana → Hepburn spelling, from the search's table (its Hepburn keys over its others).
    static let inverse: [String: String] = {
        let kunrei: Set<String> = ["si", "ti", "tu", "hu", "zi", "sya", "syu", "syo", "tya", "tyu", "tyo", "cya", "cyu", "cyo",
                                   "zya", "zyu", "zyo", "jya", "jyu", "jyo"]
        var inverse: [String: String] = ["ん": "n"]
        for (romaji, kana) in Romaji.table.sorted(by: { $0.key < $1.key })
        where !kunrei.contains(romaji) && !romaji.hasPrefix("x") && !romaji.hasPrefix("l") {
            if let existing = inverse[kana], existing.count <= romaji.count { continue }
            inverse[kana] = romaji
        }
        return inverse
    }()
}

/// Hiragana and katakana helpers for names.
enum NameKana {
    static func hiragana(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map { scalar in
            (0x30A1...0x30F6).contains(scalar.value) ? Unicode.Scalar(scalar.value - 0x60)! : scalar
        }))
    }

    /// Only kana (and ー, ・).
    static func isKana(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy { scalar in
            (0x3041...0x3096).contains(scalar.value) || (0x30A1...0x30FA).contains(scalar.value) || scalar == "ー" || scalar == "・"
        }
    }
}
