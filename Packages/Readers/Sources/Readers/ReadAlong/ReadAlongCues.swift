import Foundation

/// A prepared book's cues in reading order (start times never go back), with the lookups the
/// reader needs: the cue spoken at a time, and the cue at a place in the text.
public struct ReadAlongCues: Equatable, Sendable {
    /// Bumped when the aligner changes, so books are prepared again.
    public static let version = 1

    public let cues: [ReadAlongCue]

    public init(_ cues: [ReadAlongCue]) {
        self.cues = cues
    }

    public init?(data: Data) {
        guard let cues = try? JSONDecoder().decode([ReadAlongCue].self, from: data) else { return nil }
        self.cues = cues
    }

    public var data: Data { (try? JSONEncoder().encode(cues)) ?? Data() }

    /// The cue being spoken at `time`: the last one started by then (it stays through the
    /// pause after it). Nil before the first.
    public func index(at time: Double) -> Int? {
        var low = 0, high = cues.count
        while low < high {
            let middle = (low + high) / 2
            if cues[middle].start <= time + 0.05 { low = middle + 1 } else { high = middle }
        }
        return low == 0 ? nil : low - 1
    }

    /// The cue containing a place in the text (a tap), or the nearest one before it in that section.
    public func index(section: Int, run: Int, offset: Int) -> Int? {
        var best: Int?
        for (index, cue) in cues.enumerated() where cue.section == section {
            if (cue.run, cue.offset) <= (run, offset) { best = index } else { break }
        }
        guard let best, cues[best].run == run, offset < cues[best].offset + cues[best].length else {
            // Between cues (an unnarrated line): the next cue in the section.
            return cues.firstIndex { $0.section == section && ($0.run, $0.offset) > (run, offset) } ?? best
        }
        return best
    }

    /// The first cue in a section at or after a run (opening a page while listening).
    /// Where listening starts from a place on the page: the last matched sentence at or before
    /// it (a page's own sentences may not have matched), else the first one after it.
    public func startIndex(section: Int, run: Int, offset: Int) -> Int? {
        cues.lastIndex { ($0.section, $0.run, $0.offset) <= (section, run, offset) } ?? firstIndex(section: section, fromRun: run)
    }

    /// Where listening starts from a page: the first matched sentence on it (one running into
    /// it from the page before counts, up to where the next page starts or the section's end),
    /// else as `startIndex`.
    public func startIndex(section: Int, run: Int, offset: Int, nextPage: (run: Int, offset: Int)?) -> Int? {
        let onPage = cues.firstIndex { cue in
            cue.section == section && (cue.run > run || cue.run == run && cue.offset + cue.length > offset)
                && nextPage.map { (cue.run, cue.offset) < ($0.run, $0.offset) } ?? true
        }
        return onPage ?? startIndex(section: section, run: run, offset: offset)
    }

    public func firstIndex(section: Int, fromRun run: Int = 0) -> Int? {
        cues.firstIndex { $0.section == section && $0.run >= run } ?? cues.firstIndex { $0.section > section }
    }
}
