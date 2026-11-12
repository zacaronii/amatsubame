import Dictionary
import Foundation

/// One run of a book section's text, as `BookReader.js` `textRuns()` gives it (furigana left
/// out): positions in the book are (section, run, UTF-16 offset), the same as word marks use.
public struct BookTextRun: Codable, Equatable, Sendable {
    public var section: Int
    public var run: Int
    public var text: String

    public init(section: Int, run: Int, text: String) {
        self.section = section
        self.run = run
        self.text = text
    }
}

/// A transcript word with its time on the audiobook's timeline (seconds).
public struct TimedWord: Equatable, Sendable {
    public var text: String
    public var start: Double
    public var end: Double

    public init(text: String, start: Double, end: Double) {
        self.text = text
        self.start = start
        self.end = end
    }
}

/// A book sentence and when it's spoken: what the reader highlights and seeks to.
public struct ReadAlongCue: Codable, Equatable, Sendable {
    public var section: Int
    public var run: Int
    /// UTF-16 offset and length in the run's text.
    public var offset: Int
    public var length: Int
    public var start: Double
    public var end: Double
    /// How much of the sentence matched the transcript exactly (0…1).
    public var score: Double

    public init(section: Int, run: Int, offset: Int, length: Int, start: Double, end: Double, score: Double) {
        self.section = section
        self.run = run
        self.offset = offset
        self.length = length
        self.start = start
        self.end = end
        self.score = score
    }
}

/// Matches a book's text to its audiobook transcript, on the device.
///
/// Both sides are normalised (kana folded to hiragana, width folded, punctuation and space
/// dropped). Six-character pieces found exactly once on each side are anchors; the longest
/// chain of anchors in order on both sides is kept (stray matches drop out), and the
/// characters between two anchors are spread evenly over the time between them when the gap is
/// alike on both sides. Each book character then has a time, or none (front matter, parts not
/// read aloud, long mishearings), and a sentence is timed from its characters.
public enum ReadAlongAligner {
    static let shingle = 6
    /// A gap between anchors is interpolated only when it's at most this long on both sides…
    static let maxGap = 400
    /// …and the two sides' lengths are within this ratio (else the book and audio differ there).
    static let maxGapRatio = 2.5
    /// A sentence needs this share of its characters timed to get a cue.
    static let minimumTimed = 0.5

    public static func align(runs: [BookTextRun], words: [TimedWord]) -> [ReadAlongCue] {
        // The book: sentences, and their normalised characters with the sentence each came from.
        struct Sentence { var run: BookTextRun; var range: Range<Int>; var characters: Range<Int> }
        var bookCharacters: [UInt32] = []
        var sentences: [Sentence] = []
        for run in runs {
            let utf16 = Array(run.text.utf16)
            for range in TextScanner.sentences(in: run.text) {
                let text = String(decoding: utf16[range], as: UTF16.self)
                let first = bookCharacters.count
                bookCharacters += normalised(text)
                if bookCharacters.count > first {
                    sentences.append(Sentence(run: run, range: range, characters: first..<bookCharacters.count))
                }
            }
        }
        // The transcript: normalised characters, each with a time spread through its word.
        var spokenCharacters: [UInt32] = []
        var times: [Double] = []
        for word in words {
            let characters = normalised(word.text)
            for (index, character) in characters.enumerated() {
                spokenCharacters.append(character)
                let fraction = characters.count > 1 ? Double(index) / Double(characters.count - 1) : 0
                times.append(word.start + (word.end - word.start) * fraction)
            }
        }
        guard !bookCharacters.isEmpty, !spokenCharacters.isEmpty else { return [] }

        let anchors = chain(anchors(book: bookCharacters, spoken: spokenCharacters))
        var spokenAt = [Int?](repeating: nil, count: bookCharacters.count)
        var exact = [Bool](repeating: false, count: bookCharacters.count)
        for (book, spoken) in anchors {
            for step in 0..<shingle where book + step < bookCharacters.count && spoken + step < spokenCharacters.count {
                spokenAt[book + step] = spoken + step
                exact[book + step] = true
            }
        }
        // Between consecutive anchors, spread the book's characters over the transcript's.
        for (left, right) in zip(anchors, anchors.dropFirst()) {
            let bookFrom = left.book + shingle, bookTo = right.book
            let spokenFrom = left.spoken + shingle, spokenTo = right.spoken
            let bookGap = bookTo - bookFrom, spokenGap = spokenTo - spokenFrom
            guard bookGap > 0, spokenGap >= 0, bookGap <= maxGap, spokenGap <= maxGap else { continue }
            let ratio = Double(max(bookGap, spokenGap)) / Double(max(min(bookGap, spokenGap), 1))
            guard ratio <= maxGapRatio || max(bookGap, spokenGap) <= 8 else { continue }
            for index in bookFrom..<bookTo where spokenAt[index] == nil {
                let fraction = Double(index - bookFrom) / Double(bookGap)
                spokenAt[index] = min(spokenFrom + Int(fraction * Double(spokenGap)), spokenCharacters.count - 1)
            }
        }

        var cues: [ReadAlongCue] = []
        for sentence in sentences {
            let timed = sentence.characters.compactMap { spokenAt[$0] }
            guard !timed.isEmpty, Double(timed.count) / Double(sentence.characters.count) >= minimumTimed,
                  let first = timed.min(), let last = timed.max() else { continue }
            var start = times[first]
            let end = max(times[last], start)
            // Keep cues in order: a sentence never starts before the one before it.
            if let previous = cues.last, start < previous.start { start = previous.start }
            let score = Double(sentence.characters.filter { exact[$0] }.count) / Double(sentence.characters.count)
            cues.append(ReadAlongCue(section: sentence.run.section, run: sentence.run.run, offset: sentence.range.lowerBound,
                                     length: sentence.range.count, start: start, end: max(end, start), score: score))
        }
        return cues
    }

    /// Positions (book, spoken) of six-character pieces that occur exactly once on each side.
    static func anchors(book: [UInt32], spoken: [UInt32]) -> [(book: Int, spoken: Int)] {
        func pieces(_ characters: [UInt32]) -> [Int: Int] {
            // Piece hash → position, or -1 when it occurs more than once.
            var found: [Int: Int] = [:]
            guard characters.count >= shingle else { return found }
            for start in 0...(characters.count - shingle) {
                var hasher = Hasher()
                for offset in 0..<shingle { hasher.combine(characters[start + offset]) }
                let key = hasher.finalize()
                found[key] = found[key] == nil ? start : -1
            }
            return found
        }
        let inBook = pieces(book), inSpoken = pieces(spoken)
        var pairs: [(book: Int, spoken: Int)] = []
        for (key, bookPosition) in inBook where bookPosition >= 0 {
            if let spokenPosition = inSpoken[key], spokenPosition >= 0,
               book[bookPosition..<bookPosition + shingle].elementsEqual(spoken[spokenPosition..<spokenPosition + shingle]) {
                pairs.append((bookPosition, spokenPosition))
            }
        }
        return pairs.sorted { $0.book < $1.book }
    }

    /// The longest chain of anchors increasing on both sides (patience sorting). Pieces of one
    /// long match overlap; they agree with each other, so they all stay.
    static func chain(_ anchors: [(book: Int, spoken: Int)]) -> [(book: Int, spoken: Int)] {
        guard !anchors.isEmpty else { return [] }
        var tails: [Int] = []          // index into anchors of the smallest tail per length
        var previous = [Int](repeating: -1, count: anchors.count)
        for (index, anchor) in anchors.enumerated() {
            var low = 0, high = tails.count
            while low < high {
                let middle = (low + high) / 2
                if anchors[tails[middle]].spoken < anchor.spoken { low = middle + 1 } else { high = middle }
            }
            if low > 0 { previous[index] = tails[low - 1] }
            if low == tails.count { tails.append(index) } else { tails[low] = index }
        }
        var result: [(book: Int, spoken: Int)] = []
        var index = tails.last ?? -1
        while index >= 0 {
            result.append(anchors[index])
            index = previous[index]
        }
        return result.reversed()
    }

    /// The characters that are compared: letters and digits only, katakana folded into
    /// hiragana, full-width folded to half-width, lower case.
    static func normalised(_ text: String) -> [UInt32] {
        var result: [UInt32] = []
        for scalar in text.precomposedStringWithCompatibilityMapping.lowercased().unicodeScalars {
            let properties = scalar.properties
            guard properties.isAlphabetic || properties.numericType != nil || scalar == "ー" else { continue }
            var value = scalar.value
            if (0x30A1...0x30F6).contains(value) { value -= 0x60 }
            result.append(value)
        }
        return result
    }
}
