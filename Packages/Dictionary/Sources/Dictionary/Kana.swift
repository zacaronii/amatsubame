import Foundation

public enum Kana {
    public static func isKana(_ scalar: Unicode.Scalar) -> Bool {
        (0x3041...0x309F).contains(scalar.value) || (0x30A0...0x30FF).contains(scalar.value) || scalar.value == 0x30FC
    }

    public static func isKana(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy(isKana)
    }

    /// Katakana → hiragana (ー and other symbols unchanged), for comparing readings.
    public static func toHiragana(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map { scalar in
            (0x30A1...0x30F6).contains(scalar.value) ? Unicode.Scalar(scalar.value - 0x60)! : scalar
        }))
    }

    /// Small kana that combine with the previous kana into one mora.
    static let combining: Set<Character> = Set("ゃゅょぁぃぅぇぉゎャュョァィゥェォヮ")
}

/// Splits kana into morae, the unit pitch accent counts in: きゃく → [きゃ, く].
public enum Mora {
    public static func split(_ kana: String) -> [String] {
        var morae: [String] = []
        for character in kana {
            if Kana.combining.contains(character), let last = morae.popLast() {
                morae.append(last + String(character))
            } else {
                morae.append(String(character))
            }
        }
        return morae
    }
}

/// Pitch accent shape for a word, from its downstep position.
public struct PitchGraph: Equatable, Sendable {
    public enum Pattern: String, Sendable {
        case heiban, atamadaka, nakadaka, odaka
    }

    public var morae: [String]
    /// High/low for each mora, plus one extra entry for a following particle.
    public var highs: [Bool]
    public var downstep: Int
    public var pattern: Pattern

    public init(reading: String, downstep: Int) {
        morae = Mora.split(reading)
        self.downstep = downstep
        let count = morae.count
        highs = (0...count).map { Self.isHigh(position: $0, downstep: downstep) }
        pattern = switch downstep {
        case 0: .heiban
        case 1: .atamadaka
        case count: .odaka
        default: .nakadaka
        }
    }

    /// Tokyo-style accent: low first mora unless the drop is after it, high until the drop.
    static func isHigh(position: Int, downstep: Int) -> Bool {
        switch downstep {
        case 0: position > 0
        case 1: position == 0
        default: position > 0 && position < downstep
        }
    }
}

/// Splits a headword into kanji and kana runs and assigns each kanji run its
/// reading, for furigana: 食べる/たべる → [食:た, べる].
public enum Furigana {
    public struct Segment: Equatable, Sendable {
        public var text: String
        /// Ruby for this run; nil when the run is kana (or the reading couldn't be aligned).
        public var reading: String?

        public init(_ text: String, _ reading: String? = nil) {
            self.text = text
            self.reading = reading
        }
    }

    public static func segments(expression: String, reading: String) -> [Segment] {
        guard !reading.isEmpty, Kana.toHiragana(expression) != Kana.toHiragana(reading) else {
            return [Segment(expression)]
        }
        var groups: [(text: String, isKana: Bool)] = []
        for character in expression {
            let kana = Kana.isKana(character)
            if let last = groups.last, last.isKana == kana {
                groups[groups.count - 1].text.append(character)
            } else {
                groups.append((String(character), kana))
            }
        }
        if let aligned = align(groups[...], Array(Kana.toHiragana(reading)), original: Array(reading)) {
            return aligned
        }
        return [Segment(expression, reading)]
    }

    /// Matches kana runs literally against the reading and gives each kanji run
    /// the shortest reading that lets the rest match.
    private static func align(
        _ groups: ArraySlice<(text: String, isKana: Bool)>, _ reading: [Character], original: [Character]
    ) -> [Segment]? {
        guard let group = groups.first else { return reading.isEmpty ? [] : nil }
        let rest = groups.dropFirst()
        if group.isKana {
            let kana = Array(Kana.toHiragana(group.text))
            guard reading.starts(with: kana) else { return nil }
            return align(rest, Array(reading.dropFirst(kana.count)), original: Array(original.dropFirst(kana.count)))
                .map { [Segment(group.text)] + $0 }
        }
        let maxLength = reading.count - rest.reduce(0) { $0 + ($1.isKana ? $1.text.count : 1) }
        guard maxLength >= 1 else { return nil }
        let lengths: [Int] = rest.isEmpty ? [reading.count] : Array(1...maxLength)
        for length in lengths {
            if let tail = align(rest, Array(reading.dropFirst(length)), original: Array(original.dropFirst(length))) {
                return [Segment(group.text, String(original.prefix(length)))] + tail
            }
        }
        return nil
    }
}
