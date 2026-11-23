import Core
import Foundation

/// Find in Transcript: the lines holding the text typed, matched like the Marks search (any
/// case, full- or half-width letters).
enum TranscriptFind {
    struct Hit: Equatable {
        /// The line's index in the transcript.
        var index: Int
        /// The first match in the line, in characters (what `TappableLine` highlights).
        var range: Range<Int>
    }

    static func hits(_ query: String, in sentences: [AudioSentence]) -> [Hit] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return [] }
        return sentences.enumerated().compactMap { index, sentence in
            let text = sentence.text
            guard let found = text.range(of: needle, options: [.caseInsensitive, .widthInsensitive]) else { return nil }
            let lower = text.distance(from: text.startIndex, to: found.lowerBound)
            return Hit(index: index, range: lower..<(lower + text.distance(from: found.lowerBound, to: found.upperBound)))
        }
    }

    /// Where a new search starts: the first hit at or after the line playing (wrapping round),
    /// so it finds what's ahead rather than the top of the episode.
    static func firstHit(_ hits: [Hit], from current: Int?) -> Int? {
        guard !hits.isEmpty else { return nil }
        guard let current else { return 0 }
        return hits.firstIndex { $0.index >= current } ?? 0
    }
}
