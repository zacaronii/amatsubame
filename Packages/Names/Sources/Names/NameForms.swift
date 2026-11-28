import Foundation

/// One spelling of a character's name to look up, with its reading when it's known.
public struct NameForm: Equatable, Sendable {
    public enum Part: String, Sendable {
        case full
        case family
        case given
        /// One part of a name written with ・ (foreign names: either part).
        case part
        /// Another name they go by (AniList's alternatives).
        case alias
    }

    public var term: String
    public var reading: String?
    public var part: Part
}

/// The spellings a character can be found by: the whole name (without its space or ・, and
/// with the ・), the family and given names when the split is sure, and the Japanese aliases.
/// No honorific forms: a tap on 架空さん finds 架空 by itself.
public enum NameForms {
    static let separators = CharacterSet(charactersIn: " 　・=＝")

    public static func forms(of character: AniListCharacter, readings source: some NameReadingSource) async -> [NameForm] {
        guard let native = character.native?.trimmingCharacters(in: .whitespaces), !native.isEmpty,
              native.unicodeScalars.contains(where: isJapanese) else { return [] }
        // Descriptive "characters" ("the king", "attendant A") aren't names.
        if character.last == nil, native.contains("の") || native.hasSuffix("様") { return [] }
        let tokens = native.components(separatedBy: separators).filter { !$0.isEmpty }
        let joined = tokens.joined()
        var forms: [NameForm] = []

        if NameKana.isKana(joined) {
            // Kana says its own reading.
            forms.append(NameForm(term: joined, reading: NameKana.hiragana(joined), part: .full))
            if native.contains("・") { forms.append(NameForm(term: tokens.joined(separator: "・"), reading: NameKana.hiragana(joined), part: .full)) }
            if tokens.count > 1 {
                for token in tokens where token.count > 1 { forms.append(NameForm(term: token, reading: NameKana.hiragana(token), part: .part)) }
            }
        } else if tokens.count == 2 {
            // Japanese order: family, then given.
            let family = await reading(of: tokens[0], romaji: character.last, source: source)
            let given = await reading(of: tokens[1], romaji: character.first, source: source)
            let full = family.reading.flatMap { family in given.reading.map { family + $0 } }
            forms.append(NameForm(term: joined, reading: full, part: .full))
            forms.append(NameForm(term: tokens[0], reading: family.reading, part: .family))
            forms.append(NameForm(term: tokens[1], reading: given.reading, part: .given))
        } else if tokens.count == 1, let last = character.last, let first = character.first,
                  let split = await split(joined, family: last, given: first, source: source) {
            forms.append(NameForm(term: joined, reading: split.family.reading + split.given.reading, part: .full))
            forms.append(NameForm(term: split.family.term, reading: split.family.reading, part: .family))
            forms.append(NameForm(term: split.given.term, reading: split.given.reading, part: .given))
        } else {
            // One name, or a split that isn't sure: the whole name only.
            let romaji = [character.last, character.first].compactMap(\.self).joined()
            let full = await reading(of: joined, romaji: romaji.isEmpty ? character.full : romaji, source: source)
            forms.append(NameForm(term: joined, reading: full.reading, part: .full))
        }

        for alternative in character.alternative {
            guard let alias = await self.alias(alternative, source: source) else { continue }
            forms.append(alias)
        }
        var seen = Set<String>()
        return forms.filter { form in
            seen.insert(form.term + "\u{0}" + (form.reading ?? "")).inserted
        }
    }

    /// "Mugiwara no Luffy (麦わらのルフィ)": the Japanese part, read from the romaji. An
    /// alternative that is Japanese alone is kept when it's kana (its reading is sure).
    static func alias(_ alternative: String, source: some NameReadingSource) async -> NameForm? {
        if let open = alternative.lastIndex(of: "("), alternative.hasSuffix(")") {
            let japanese = String(alternative[alternative.index(after: open)..<alternative.index(before: alternative.endIndex)])
                .trimmingCharacters(in: .whitespaces)
            let romaji = alternative[..<open].trimmingCharacters(in: .whitespaces)
            guard japanese.unicodeScalars.contains(where: isJapanese) else { return nil }
            let term = japanese.components(separatedBy: separators).joined()
            return NameForm(term: term, reading: await reading(of: term, romaji: romaji, source: source).reading, part: .alias)
        }
        let term = alternative.components(separatedBy: separators).joined()
        guard NameKana.isKana(term) else { return nil }
        return NameForm(term: term, reading: NameKana.hiragana(term), part: .alias)
    }

    struct Reading {
        var reading: String?
        /// JMnedict agrees, or the part is kana that spells the romaji.
        var confirmed: Bool
    }

    /// The reading of one spelling from its romaji: kana reads itself; else JMnedict's reading
    /// that spells the romaji; else the romaji's own kana when it isn't unsure.
    static func reading(of term: String, romaji: String?, source: some NameReadingSource) async -> Reading {
        if NameKana.isKana(term) {
            let kana = NameKana.hiragana(term)
            return Reading(reading: kana, confirmed: romaji.map { NameRomaji.key(NameRomaji.romaji(fromKana: kana)) == NameRomaji.key($0) } ?? false)
        }
        guard let romaji, !romaji.isEmpty else { return Reading(reading: nil, confirmed: false) }
        let known = await source.readings(of: term).map(NameKana.hiragana)
        let key = NameRomaji.key(romaji)
        if let match = known.first(where: { NameRomaji.key(NameRomaji.romaji(fromKana: $0)) == key }) {
            return Reading(reading: match, confirmed: true)
        }
        // AniList sometimes drops a long vowel (Yuki for ゆうき): one JMnedict reading that agrees.
        let short = NameRomaji.shortKey(romaji)
        let loose = Set(known.filter { NameRomaji.shortKey(NameRomaji.romaji(fromKana: $0)) == short })
        if loose.count == 1, let match = loose.first { return Reading(reading: match, confirmed: true) }
        guard let converted = NameRomaji.hiragana(romaji), !converted.unsure else { return Reading(reading: nil, confirmed: false) }
        return Reading(reading: converted.kana, confirmed: false)
    }

    struct Split {
        var family: (term: String, reading: String)
        var given: (term: String, reading: String)
    }

    /// Where a name written without a space splits into family and given: the first place
    /// where both halves read as AniList's family and given names, each confirmed (by JMnedict,
    /// or as kana spelling it: 夢見|ひかり).
    static func split(_ native: String, family: String, given: String, source: some NameReadingSource) async -> Split? {
        let characters = Array(native)
        guard characters.count > 1 else { return nil }
        for index in 1..<characters.count {
            let head = String(characters[..<index]), tail = String(characters[index...])
            let familyReading = await reading(of: head, romaji: family, source: source)
            guard familyReading.confirmed, let familyKana = familyReading.reading else { continue }
            let givenReading = await reading(of: tail, romaji: given, source: source)
            guard givenReading.confirmed, let givenKana = givenReading.reading else { continue }
            return Split(family: (head, familyKana), given: (tail, givenKana))
        }
        return nil
    }

    static func isJapanese(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isIdeographic || (0x3041...0x30FA).contains(scalar.value) || scalar == "々"
    }
}
