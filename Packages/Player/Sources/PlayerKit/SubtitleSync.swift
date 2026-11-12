import Foundation

/// Lines up a subtitle file with a reference (another subtitle track's lines, or the speech
/// found in the audio), the way alass does: both become time spans, and the subtitle is
/// shifted to overlap the reference as much as possible. It may also split the subtitle into
/// parts with different shifts (an ad break, a longer intro), each split costing a penalty.
/// Lines never change order.
public enum SubtitleSync {
    public struct Span: Equatable, Sendable {
        public var start: Double
        public var end: Double

        public init(start: Double, end: Double) {
            self.start = start
            self.end = end
        }

        var length: Double { end - start }
    }

    /// One stretch of the subtitle and how far it moves (positive = later).
    public struct Part: Equatable, Sendable {
        /// Where the part starts in the original timing (the first part starts at -infinity).
        public var from: Double
        public var shift: Double
    }

    public struct Result: Equatable, Sendable {
        public var parts: [Part]
        /// How much of the subtitle's spoken time lands on the reference after syncing (0–1).
        public var match: Double

        /// The shift for a time in the original file.
        public func shift(at time: Double) -> Double {
            parts.last { $0.from <= time }?.shift ?? parts.first?.shift ?? 0
        }
    }

    public struct Options: Sendable {
        /// The largest shift tried, in seconds either way.
        public var maxShift: Double = 300
        /// Splits allowed at all.
        public var allowsSplits = true
        /// The cost of a split, on alass's scale. alass defaults to 7; on typical anime episodes
        /// that split around opening songs and previews, while 20 still finds real breaks.
        public var splitPenalty: Double = 20

        public init(maxShift: Double = 300, allowsSplits: Bool = true, splitPenalty: Double = 20) {
            self.maxShift = maxShift
            self.allowsSplits = allowsSplits
            self.splitPenalty = splitPenalty
        }
    }

    /// The lines of a track as spans, merged where they touch or overlap.
    public static func spans(_ track: SubtitleTrack) -> [Span] {
        merged(track.cues.map { Span(start: $0.start, end: $0.end) })
    }

    public static func merged(_ spans: [Span]) -> [Span] {
        var result: [Span] = []
        for span in spans.filter({ $0.end > $0.start }).sorted(by: { $0.start < $1.start }) {
            if let last = result.last, span.start <= last.end + 0.01 {
                result[result.count - 1].end = max(last.end, span.end)
            } else {
                result.append(span)
            }
        }
        return result
    }

    /// Nil when there's too little to go on.
    public static func align(_ subtitle: [Span], to reference: [Span], options: Options = Options()) -> Result? {
        let subtitle = merged(subtitle), reference = merged(reference)
        guard subtitle.count >= 3, reference.count >= 3 else { return nil }
        let coarse = Grid(step: 0.1, maxShift: options.maxShift)
        let segments = options.allowsSplits
            ? splitShifts(subtitle, reference, grid: coarse, penalty: penalty(options.splitPenalty, subtitle, reference))
            : [(0, constantShift(subtitle, reference, grid: coarse))]
        // Fine-tune each part to 10 ms around its coarse shift.
        var parts: [Part] = []
        for (index, segment) in segments.enumerated() {
            let end = index + 1 < segments.count ? segments[index + 1].first : subtitle.count
            let spans = Array(subtitle[segment.first..<end])
            let shift = refine(spans, reference, around: segment.shift, range: coarse.step * 1.5, step: 0.01)
            let from = segment.first == 0 ? -Double.infinity : subtitle[segment.first].start
            if let last = parts.last, abs(last.shift - shift) < 0.005 { continue }
            parts.append(Part(from: from, shift: shift))
        }
        let total = subtitle.reduce(0) { $0 + $1.length }
        var matched = 0.0
        for (index, part) in parts.enumerated() {
            let next = index + 1 < parts.count ? parts[index + 1].from : .infinity
            let spans = subtitle.filter { $0.start >= part.from && $0.start < next }
            matched += overlap(spans, reference, shift: part.shift)
        }
        return Result(parts: parts, match: total > 0 ? min(matched / total, 1) : 0)
    }

    // MARK: Scoring

    /// Shifts on a grid, as indices: index 0 is -maxShift.
    struct Grid {
        let step: Double
        let count: Int
        let maxShift: Double

        init(step: Double, maxShift: Double) {
            self.step = step
            self.maxShift = maxShift
            count = Int((2 * maxShift / step).rounded()) + 1
        }

        func shift(_ index: Int) -> Double { Double(index) * step - maxShift }
    }

    /// alass scales its split penalty by the number of spans (a matched pair rates about 1
    /// there); ratings here are seconds of overlap, so it's also scaled by a typical line length.
    static func penalty(_ normalized: Double, _ subtitle: [Span], _ reference: [Span]) -> Double {
        let typical = subtitle.reduce(0) { $0 + $1.length } / Double(subtitle.count)
        return Double(min(subtitle.count, reference.count)) * normalized / 1000 * typical
    }

    /// How much a pair of spans counts when they overlap: similar lengths count more (alass's
    /// "standard scoring"), so a short line isn't pulled onto any long stretch of speech.
    static func weight(_ a: Span, _ b: Span) -> Double {
        min(a.length, b.length) / max(a.length, b.length)
    }

    /// The rating of one subtitle span at every shift of the grid: the weighted overlap with
    /// the reference spans. Each pair's overlap is a trapezoid in the shift, written as four
    /// ramps `max(shift - point, 0)`; a ramp adds `shift - point` from the first grid point
    /// past its point on, kept as running coefficients so every shift costs O(1).
    static func ratings(_ span: Span, _ reference: [Span], grid: Grid, into ratings: inout [Double],
                        slopes: inout [Double], offsets: inout [Double], firstReference: inout Int) {
        for index in slopes.indices {
            slopes[index] = 0
            offsets[index] = 0
        }
        let low = span.start - grid.maxShift, high = span.end + grid.maxShift
        while firstReference < reference.count, reference[firstReference].end < low { firstReference += 1 }
        var j = firstReference
        while j < reference.count, reference[j].start <= high {
            let other = reference[j]
            j += 1
            let w = weight(span, other)
            let short = min(span.length, other.length)
            // Rises from (other.start - span.end), flat while the shorter one is inside the
            // longer, back to zero at (other.end - span.start).
            let rise = other.start - span.end, fall = other.end - span.start
            for (point, sign) in [(rise, w), (rise + short, -w), (fall - short, -w), (fall, w)] {
                let index = max(Int(((point + grid.maxShift) / grid.step).rounded(.up)), 0)
                guard index < grid.count else { continue }
                slopes[index] += sign
                offsets[index] -= sign * point
            }
        }
        var slope = 0.0, offset = 0.0
        for index in 0..<grid.count {
            slope += slopes[index]
            offset += offsets[index]
            ratings[index] = max(slope * grid.shift(index) + offset, 0)
        }
    }

    static func constantShift(_ subtitle: [Span], _ reference: [Span], grid: Grid) -> Double {
        var total = [Double](repeating: 0, count: grid.count)
        var row = [Double](repeating: 0, count: grid.count), slopes = row, offsets = row
        var first = 0
        for span in subtitle {
            ratings(span, reference, grid: grid, into: &row, slopes: &slopes, offsets: &offsets, firstReference: &first)
            for index in total.indices { total[index] += row[index] }
        }
        return grid.shift(best(total))
    }

    /// Splits by dynamic programming over the subtitle spans in order: each keeps the
    /// previous span's shift, or jumps (paying the penalty) to a shift that keeps it after
    /// the previous span. Returns each part's first span and coarse shift.
    static func splitShifts(_ subtitle: [Span], _ reference: [Span], grid: Grid, penalty: Double) -> [(first: Int, shift: Double)] {
        let k = grid.count
        var score = [Double](repeating: 0, count: k)
        var row = score, slopes = score, offsets = score, prefix = score
        var prefixIndex = [Int32](repeating: 0, count: k)
        // For each span and shift, the shift index of the span before it.
        var from = [[Int32]](repeating: [], count: subtitle.count)
        var first = 0
        for (i, span) in subtitle.enumerated() {
            ratings(span, reference, grid: grid, into: &row, slopes: &slopes, offsets: &offsets, firstReference: &first)
            var choice = [Int32](repeating: 0, count: k)
            if i == 0 {
                score = row
                for index in 0..<k { choice[index] = Int32(index) }
            } else {
                // The best previous score at or below each shift (a jump may only go to a
                // shift where this span still starts after the previous one ends).
                var bestValue = -Double.infinity, bestIndex: Int32 = 0
                for index in 0..<k {
                    if score[index] > bestValue { bestValue = score[index]; bestIndex = Int32(index) }
                    prefix[index] = bestValue
                    prefixIndex[index] = bestIndex
                }
                let gap = Int(((span.start - subtitle[i - 1].end) / grid.step).rounded(.down))
                var next = score
                for index in 0..<k {
                    let reach = min(index + max(gap, 0), k - 1)
                    let jump = prefix[reach] - penalty
                    if jump > score[index] {
                        next[index] = jump + row[index]
                        choice[index] = prefixIndex[reach]
                    } else {
                        next[index] = score[index] + row[index]
                        choice[index] = Int32(index)
                    }
                }
                score = next
            }
            from[i] = choice
        }
        // Walk back from the best final shift.
        var index = best(score)
        var shifts = [Int](repeating: 0, count: subtitle.count)
        for i in stride(from: subtitle.count - 1, through: 0, by: -1) {
            shifts[i] = index
            index = Int(from[i][index])
        }
        var segments: [(first: Int, shift: Double)] = []
        for (i, shift) in shifts.enumerated() where i == 0 || shift != shifts[i - 1] {
            segments.append((i, grid.shift(shift)))
        }
        return segments
    }

    private static func best(_ values: [Double]) -> Int {
        // Ties go to the smallest move.
        var bestIndex = values.count / 2, bestValue = values[bestIndex]
        for (index, value) in values.enumerated() where value > bestValue + 1e-9 {
            bestValue = value
            bestIndex = index
        }
        return bestIndex
    }

    /// The best shift near `center`, checked directly in small steps.
    static func refine(_ spans: [Span], _ reference: [Span], around center: Double, range: Double, step: Double) -> Double {
        var bestShift = center, bestValue = -1.0
        let steps = Int((range / step).rounded())
        for n in -steps...steps {
            let shift = center + Double(n) * step
            let value = weightedOverlap(spans, reference, shift: shift)
            if value > bestValue + 1e-9 || (abs(value - bestValue) <= 1e-9 && abs(shift - center) < abs(bestShift - center)) {
                bestValue = value
                bestShift = shift
            }
        }
        return (bestShift * 1000).rounded() / 1000
    }

    static func weightedOverlap(_ spans: [Span], _ reference: [Span], shift: Double) -> Double {
        pairs(spans, reference, shift: shift).reduce(0) { $0 + $1.overlap * weight($1.span, $1.other) }
    }

    static func overlap(_ spans: [Span], _ reference: [Span], shift: Double) -> Double {
        pairs(spans, reference, shift: shift).reduce(0) { $0 + $1.overlap }
    }

    private static func pairs(_ spans: [Span], _ reference: [Span], shift: Double) -> [(span: Span, other: Span, overlap: Double)] {
        var result: [(Span, Span, Double)] = []
        var j = 0
        for span in spans {
            let start = span.start + shift, end = span.end + shift
            while j < reference.count, reference[j].end <= start { j += 1 }
            var m = j
            while m < reference.count, reference[m].start < end {
                let amount = min(end, reference[m].end) - max(start, reference[m].start)
                if amount > 0 { result.append((span, reference[m], amount)) }
                m += 1
            }
        }
        return result
    }
}
