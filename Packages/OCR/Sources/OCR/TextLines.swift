import CoreGraphics
import Foundation

/// Finds a block's real lines of lettering (columns of vertical text, rows of horizontal) in
/// its picture, so a tap can be matched to the character under it. The recognizer gives a
/// block's text and box but not where each character sits, and spreading the characters evenly
/// over the box is wrong whenever the columns differ in length or there's furigana.
public enum TextLines {
    /// Raised when the measuring changes, so pages measured by an older one are measured again.
    public static let version = 2

    /// The block's picture as ink, addressed across the lines (`a`: x for vertical text) and
    /// along them (`l`).
    struct Ink {
        let mask: [Bool]
        let width: Int, height: Int
        let vertical: Bool
        var across: Int { vertical ? width : height }
        var along: Int { vertical ? height : width }

        func isInk(_ a: Int, _ l: Int) -> Bool { vertical ? mask[l * width + a] : mask[a * width + l] }

        /// The first and last place along the lines with ink anywhere in `range` across.
        func extent(across range: ClosedRange<Int>) -> ClosedRange<Int>? {
            var first: Int?, last: Int?
            for l in 0..<along where range.contains(where: { isInk($0, l) }) {
                if first == nil { first = l }
                last = l
            }
            guard let first, let last else { return nil }
            return first...last
        }
    }

    /// A line of lettering: where it is across the block and along it, in pixels.
    struct Line {
        var across: ClosedRange<Int>
        var along: ClosedRange<Int>
    }

    /// The lines in reading order (vertical text: right to left), each as a rect in the block's
    /// own unit square (0…1, origin top-left) around its ink. Empty when nothing can be told
    /// apart (then the even spread is used). `characterCount` (when known) helps with a short
    /// line of characters that have gaps in them (川, い).
    public static func lines(gray: [UInt8], width: Int, height: Int, vertical: Bool, characterCount: Int = 0) -> [CGRect] {
        guard width > 2, height > 2, gray.count == width * height else { return [] }
        let ink = Ink(mask: inkMask(gray), width: width, height: height, vertical: vertical)
        return found(in: ink, characterCount: characterCount).lines.map { rect($0, in: ink) }
    }

    static func rect(_ line: Line, in ink: Ink) -> CGRect {
        let a0 = CGFloat(line.across.lowerBound) / CGFloat(ink.across), a1 = CGFloat(line.across.upperBound + 1) / CGFloat(ink.across)
        let l0 = CGFloat(line.along.lowerBound) / CGFloat(ink.along), l1 = CGFloat(line.along.upperBound + 1) / CGFloat(ink.along)
        return ink.vertical ? CGRect(x: a0, y: l0, width: a1 - a0, height: l1 - l0) : CGRect(x: l0, y: a0, width: l1 - l0, height: a1 - a0)
    }

    /// The lines in reading order, and how thick a full line is (`size`: about one character).
    /// `known` is the size when it has been measured another way (from the grid's pitch).
    static func found(in ink: Ink, characterCount: Int, size known: Int? = nil) -> (lines: [Line], size: Int) {
        let across = ink.across, along = ink.along
        var profile = [Int](repeating: 0, count: across)
        for a in 0..<across {
            for l in 0..<along where ink.isInk(a, l) { profile[a] += 1 }
        }
        // A stray speck isn't lettering.
        let floor = max(1, along / 100)
        var runs: [ClosedRange<Int>] = []
        var start: Int?
        for a in 0..<across {
            if profile[a] >= floor {
                if start == nil { start = a }
            } else if let from = start {
                runs.append(from...(a - 1))
                start = nil
            }
        }
        if let from = start { runs.append(from...(across - 1)) }
        guard !runs.isEmpty else { return ([], 0) }

        // How thick a full line is. Most runs are full lines; one with its furigana stuck to it
        // is half as thick again, so it isn't the measure.
        let widths = runs.map(\.count).sorted()
        let widest = widths.last ?? 1
        let full = widths.filter { Double($0) >= Double(widest) * 0.6 }
        let median = full[(full.count - 1) / 2]
        var size = full.last { Double($0) <= Double(median) * 1.3 } ?? median
        // A short line of characters with gaps in them (川, い) is in pieces thinner than a
        // character: a line of `characterCount` characters is at least that long per character.
        if characterCount > 0 {
            let longest = runs.compactMap { ink.extent(across: $0)?.count }.max() ?? 0
            size = min(across, max(size, longest / characterCount))
        }
        if let known { size = known }
        let unit = Double(size)
        // Furigana that touches its line, or two lines that touch: part them where the ink
        // all but stops.
        runs = runs.flatMap { Double($0.count) > unit * 1.3 ? partedAtValleys($0, profile: profile) : [$0] }

        // Pieces of one line: close together, and together no thicker than a line.
        var joined: [ClosedRange<Int>] = []
        for run in runs {
            if let last = joined.last, Double(run.lowerBound - last.upperBound - 1) < unit * 0.35,
               Double(run.upperBound - last.lowerBound + 1) <= unit * 1.15 {
                joined[joined.count - 1] = last.lowerBound...run.upperBound
            } else {
                joined.append(run)
            }
        }
        // Thicker than a line: lines that touch are cut apart; a line with its furigana stuck
        // to it keeps the line's side (furigana is to the right of a column, above a row).
        var parted: [ClosedRange<Int>] = []
        for run in joined {
            let thickness = Double(run.count)
            if thickness >= unit * 1.85 {
                let parts = Int((thickness / unit).rounded())
                var from = run.lowerBound
                for part in 1...parts {
                    let even = run.lowerBound + Int(thickness * Double(part) / Double(parts))
                    let reach = max(1, size / 5)
                    let cut = part == parts ? run.upperBound + 1
                        : (max(from + 1, even - reach)...max(from + 1, min(run.upperBound, even + reach))).min { (profile[$0], abs($0 - even)) < (profile[$1], abs($1 - even)) } ?? even
                    if cut > from { parted.append(from...(cut - 1)) }
                    from = cut
                }
            } else if thickness > unit * 1.3 {
                parted.append(ink.vertical ? run.lowerBound...(run.lowerBound + size - 1) : (run.upperBound - size + 1)...run.upperBound)
            } else {
                parted.append(run)
            }
        }
        // Furigana runs beside its line at about half the size, almost touching it: not a line
        // of its own. A thin line on its own (…？, ！) keeps its distance and is one.
        var lines: [Line] = []
        for (index, run) in parted.enumerated() {
            guard let extent = ink.extent(across: run) else { continue }
            if Double(run.count) < unit * 0.62 {
                // Within reach of the nearest full line on the side furigana is set on.
                let bases = ink.vertical ? Array(parted[..<index].reversed()) : Array(parted[(index + 1)...])
                if let base = bases.first(where: { Double($0.count) >= unit * 0.62 }) {
                    let reach = ink.vertical ? run.upperBound - base.upperBound : base.lowerBound - run.lowerBound
                    if Double(reach) < unit * 0.72 { continue }
                }
                // A speck.
                if Double(extent.count) < unit * 0.4, parted.count > 1 { continue }
                // An unbroken stroke much longer than a character: an outline, not lettering.
                if Double(extent.count) > unit * 2 {
                    let covered = extent.filter { l in run.contains { ink.isInk($0, l) } }.count
                    if Double(covered) > Double(extent.count) * 0.92 { continue }
                }
            }
            lines.append(Line(across: run, along: extent))
        }
        // Furigana for a shorter neighbour's last words can sit in line with a line, past its
        // end (or before its start): a stretch apart from the rest and half as thick isn't
        // part of the line.
        let whole = lines
        lines = lines.indices.map { index in
            let line = whole[index]
            var stretches: [ClosedRange<Int>] = []
            var blank = 0
            for l in line.along {
                if line.across.contains(where: { ink.isInk($0, l) }) {
                    if let last = stretches.last, Double(blank) < unit * 0.5 {
                        stretches[stretches.count - 1] = last.lowerBound...l
                    } else {
                        stretches.append(l...l)
                    }
                    blank = 0
                } else {
                    blank += 1
                }
            }
            // Thin, on the side of the line it would belong to, and beside that line.
            let base = ink.vertical ? (index > 0 ? whole[index - 1] : nil) : (index + 1 < whole.count ? whole[index + 1] : nil)
            func isThin(_ stretch: ClosedRange<Int>) -> Bool {
                guard let base, base.along.overlaps(stretch) else { return false }
                let inked = line.across.filter { a in stretch.contains { ink.isInk(a, $0) } }
                guard let low = inked.first, let high = inked.last else { return true }
                return ink.vertical ? Double(high - line.across.lowerBound) < unit * 0.55 : Double(line.across.upperBound - low) < unit * 0.55
            }
            guard stretches.count > 1, stretches.contains(where: { !isThin($0) }) else { return line }
            while stretches.count > 1, let last = stretches.last, isThin(last), Double(last.count) > unit * 0.5 { stretches.removeLast() }
            while stretches.count > 1, let first = stretches.first, isThin(first), Double(first.count) > unit * 0.5 { stretches.removeFirst() }
            return Line(across: line.across, along: stretches[0].lowerBound...stretches[stretches.count - 1].upperBound)
        }
        return (ink.vertical ? lines.reversed() : lines, size)
    }

    /// A run of the profile cut where it dips to under a quarter of what's on both sides.
    private static func partedAtValleys(_ run: ClosedRange<Int>, profile: [Int]) -> [ClosedRange<Int>] {
        guard run.count >= 5 else { return [run] }
        let highest = run.map { profile[$0] }.max() ?? 0
        var before = [Int](repeating: 0, count: run.count), after = before
        var most = 0
        for (offset, a) in run.enumerated() {
            before[offset] = most
            most = max(most, profile[a])
        }
        most = 0
        for (offset, a) in run.enumerated().reversed() {
            after[offset] = most
            most = max(most, profile[a])
        }
        var best: (at: Int, depth: Double)?
        for (offset, a) in run.enumerated() where offset >= 2 && offset < run.count - 2 {
            let sides = min(before[offset], after[offset])
            guard Double(sides) >= Double(highest) * 0.2, sides > 0 else { continue }
            let depth = Double(profile[a]) / Double(sides)
            if depth < 0.25, depth < (best?.depth ?? 1) { best = (a, depth) }
        }
        guard let best else { return [run] }
        return partedAtValleys(run.lowerBound...(best.at - 1), profile: profile) + partedAtValleys((best.at + 1)...run.upperBound, profile: profile)
    }

    /// Where each of the block's `count` characters sits, in reading order and in the block's
    /// unit square, without assuming a grid. Every line gets its share of the characters by its
    /// length; along the line the glyphs themselves are found by the gaps between them, so a
    /// character's place is the glyph's own, whatever its width (a narrow 1, a colon). Empty
    /// when it can't be told.
    public static func cells(gray: [UInt8], width: Int, height: Int, vertical: Bool, lines: [CGRect], count: Int) -> [CGRect] {
        guard width > 2, height > 2, gray.count == width * height else { return [] }
        return cellsByGaps(ink: Ink(mask: inkMask(gray), width: width, height: height, vertical: vertical), lines: lines, count: count).cells
    }

    /// `exact` when every line had exactly as many glyphs as characters, so nothing was guessed.
    static func cellsByGaps(ink: Ink, lines: [CGRect], count: Int) -> (cells: [CGRect], exact: Bool) {
        guard count > 0, !lines.isEmpty, lines.count <= count else { return ([], false) }
        let vertical = ink.vertical
        let across = ink.across, along = ink.along
        func isInk(_ a: Int, _ l: Int) -> Bool { ink.isInk(a, l) }
        var exact = true
        let counts = TextLayout.characterCounts(lines.map { vertical ? $0.height : $0.width }, total: count)
        var cells: [CGRect] = []
        for (line, characters) in zip(lines, counts) {
            let a0 = max(0, Int(((vertical ? line.minX : line.minY) * CGFloat(across)).rounded()))
            let a1 = min(across, Int(((vertical ? line.maxX : line.maxY) * CGFloat(across)).rounded()))
            let l0 = max(0, Int(((vertical ? line.minY : line.minX) * CGFloat(along)).rounded()))
            let l1 = min(along, Int(((vertical ? line.maxY : line.maxX) * CGFloat(along)).rounded()))
            guard characters > 0, a1 > a0, l1 > l0 else { return ([], false) }
            // The glyphs along the line: stretches with ink, parted by places with none across
            // the line's whole thickness.
            var profile = [Int](repeating: 0, count: l1 - l0)
            for l in l0..<l1 {
                for a in a0..<a1 where isInk(a, l) { profile[l - l0] += 1 }
            }
            var glyphs: [ClosedRange<Int>] = []
            var start: Int?
            for l in l0..<l1 {
                if profile[l - l0] > 0 {
                    if start == nil { start = l }
                } else if let from = start {
                    glyphs.append(from...(l - 1))
                    start = nil
                }
            }
            if let from = start { glyphs.append(from...(l1 - 1)) }
            guard !glyphs.isEmpty else { return ([], false) }
            if glyphs.count != characters { exact = false }
            // More pieces than characters: some characters are in parts (い, ふ, 二, a colon
            // after its word). The parts of one character are the closest together, and together
            // no longer than a character is: the line is about one character thick.
            let thickness = a1 - a0
            while glyphs.count > characters {
                func gap(_ index: Int) -> Int { glyphs[index + 1].lowerBound - glyphs[index].upperBound }
                func whole(_ index: Int) -> Int { glyphs[index + 1].upperBound - glyphs[index].lowerBound + 1 }
                let pairs = Array(0..<(glyphs.count - 1))
                let fitting = pairs.filter { Double(whole($0)) <= Double(thickness) * 1.25 }
                let index = (fitting.isEmpty ? pairs : fitting).min { (gap($0), whole($0)) < (gap($1), whole($1)) } ?? 0
                glyphs[index] = glyphs[index].lowerBound...glyphs[index + 1].upperBound
                glyphs.remove(at: index + 1)
            }
            // Fewer: some glyphs touch (bold lettering). Each stretch holds its share of the
            // characters by its length, cut where the ink is thinnest near an even cut.
            let shares = glyphs.count == characters
                ? glyphs.map { _ in 1 }
                : TextLayout.characterCounts(glyphs.map { CGFloat($0.count) }, total: characters)
            var cuts = [Double(l0)]
            for (index, glyph) in glyphs.enumerated() {
                let share = shares[index], size = Double(glyph.count) / Double(share)
                for part in 1..<max(share, 1) {
                    let even = Double(glyph.lowerBound) + size * Double(part)
                    let reach = max(1, Int(size * 0.35))
                    let low = max(glyph.lowerBound + 1, Int(even) - reach), high = min(glyph.upperBound, Int(even) + reach)
                    let thinnest = low <= high
                        ? (low...high).min { (profile[$0 - l0], abs(Double($0) - even)) < (profile[$1 - l0], abs(Double($1) - even)) }
                        : nil
                    cuts.append(max(Double(thinnest ?? Int(even)), (cuts.last ?? 0) + 1))
                }
                // To the middle of the gap before the next stretch.
                cuts.append(index < glyphs.count - 1 ? Double(glyph.upperBound + 1 + glyphs[index + 1].lowerBound) / 2 : Double(l1))
            }
            guard cuts.count == characters + 1 else { return ([], false) }
            for index in 0..<characters {
                let from = CGFloat(min(cuts[index], Double(l1))) / CGFloat(along)
                let to = CGFloat(min(max(cuts[index + 1], cuts[index]), Double(l1))) / CGFloat(along)
                cells.append(vertical
                    ? CGRect(x: line.minX, y: from, width: line.width, height: to - from)
                    : CGRect(x: from, y: line.minY, width: to - from, height: line.height))
            }
        }
        return cells.count == count ? (cells, exact) : ([], false)
    }

    /// The lines of a block cut out of its page.
    public static func lines(of box: NormalizedRect, in image: CGImage, vertical: Bool) -> [CGRect] {
        layout(of: box, in: image, vertical: vertical, text: "").lines
    }

    /// A block's lines and its characters' places, from its part of the page.
    public struct Layout: Sendable {
        public var lines: [CGRect] = []
        public var cells: [CGRect] = []
        /// Whether every character was found in the lettering (the places can be drawn on the
        /// page), or the places are a best guess (good enough to aim a tap by).
        public var exact = false
    }

    public static func layout(of box: NormalizedRect, in image: CGImage, vertical: Bool, text: String) -> Layout {
        let page = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let pixels = box.pixels(in: page.size).integral.intersection(page)
        guard pixels.width >= 4, pixels.height >= 4 else { return Layout() }
        // A little more than the block, so that its glyphs stand clear of the edge and what
        // runs off the edge (the bubble's outline, the art) can be told from them.
        let margin = (max(pixels.width, pixels.height) * 0.04).rounded(.up)
        let padded = pixels.insetBy(dx: -margin, dy: -margin).intersection(page)
        guard let crop = image.cropping(to: padded) else { return Layout() }
        // Small enough to be quick, large enough to keep the thin gaps between glyphs (a small
        // block on a low-resolution page is enlarged).
        let longest = max(padded.width, padded.height)
        let scale = longest > 1000 ? 1000 / longest : longest < 320 ? 2 : 1
        let width = max(4, Int(padded.width * scale)), height = max(4, Int(padded.height * scale))
        guard let gray = ImagePreprocessing.grayPixels(crop, width: width, height: height) else { return Layout() }
        var layout = layout(gray: gray, width: width, height: height, vertical: vertical, text: text, clearingEdges: true)
        // From the larger picture's unit square back to the block's.
        func inBlock(_ rect: CGRect) -> CGRect {
            let x = (rect.minX * padded.width + padded.minX - pixels.minX) / pixels.width
            let y = (rect.minY * padded.height + padded.minY - pixels.minY) / pixels.height
            return CGRect(x: x, y: y, width: rect.width * padded.width / pixels.width, height: rect.height * padded.height / pixels.height)
                .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        layout.lines = layout.lines.map(inBlock).filter { !$0.isNull && !$0.isEmpty }
        let cells = layout.cells.map(inBlock)
        // A place wholly outside the block isn't one a tap can reach or a mark can show.
        layout.cells = cells.contains { $0.isNull || $0.isEmpty } ? [] : cells
        if layout.cells.isEmpty { layout.exact = false }
        return layout
    }

    public static func layout(gray: [UInt8], width: Int, height: Int, vertical: Bool, text: String, clearingEdges: Bool = false) -> Layout {
        guard width > 2, height > 2, gray.count == width * height else { return Layout() }
        var mask = inkMask(gray)
        if clearingEdges { clearEdges(&mask, width: width, height: height) }
        let ink = Ink(mask: mask, width: width, height: height, vertical: vertical)
        let characters = Array(text)
        var (lines, size) = found(in: ink, characterCount: characters.count)
        guard !lines.isEmpty, !characters.isEmpty else { return Layout(lines: lines.map { rect($0, in: ink) }) }
        // Japanese lettering is set on a grid, one character to a square: find the grid, then
        // match the text to its squares.
        var grid = size > 3 ? grid(lines, size: size, in: ink) : nil
        // The grid's pitch says how thick a line is better than the lines themselves do, when
        // furigana is stuck to them: find the lines again by it.
        if let found = grid, found.crossing < 0.1, abs(found.pitch / 1.05 - Double(size)) > Double(size) * 0.12 {
            let again = Self.found(in: ink, characterCount: characters.count, size: Int((found.pitch / 1.05).rounded()))
            if !again.lines.isEmpty, let refit = Self.grid(again.lines, size: again.size, in: ink), refit.crossing <= found.crossing + 0.02 {
                (lines, size, grid) = (again.lines, again.size, refit)
            }
        }
        var layout = Layout(lines: lines.map { rect($0, in: ink) })
        func rects(_ places: [Place]) -> [CGRect] {
            places.map { cell in
                let a0 = CGFloat(cell.across.lowerBound) / CGFloat(ink.across), a1 = CGFloat(cell.across.upperBound + 1) / CGFloat(ink.across)
                let l0 = cell.from / CGFloat(ink.along), l1 = cell.to / CGFloat(ink.along)
                let rect = vertical ? CGRect(x: a0, y: l0, width: a1 - a0, height: l1 - l0) : CGRect(x: l0, y: a0, width: l1 - l0, height: a1 - a0)
                guard cell.parts > 1 else { return rect }
                // Characters set side by side in one square (！？ in a column).
                let share = (vertical ? rect.width : rect.height) / CGFloat(cell.parts)
                return vertical
                    ? CGRect(x: rect.minX + share * CGFloat(cell.part), y: rect.minY, width: share, height: rect.height)
                    : CGRect(x: rect.minX, y: rect.minY + share * CGFloat(cell.part), width: rect.width, height: share)
            }
        }
        if let grid, grid.crossing < 0.1 {
            if let match = placed(characters, in: grid.cells, pitch: grid.pitch, vertical: vertical), match.cost <= 1 {
                layout.cells = rects(match.places)
                layout.exact = true
                return layout
            }
            // A stray mark beside the lettering (a piece of the bubble's outline, a sweat drop)
            // makes a line of its own: without it, the text may fit exactly.
            if lines.count > 1 {
                for line in lines.indices.sorted(by: { lines[$0].along.count < lines[$1].along.count }) {
                    let kept = grid.cells.filter { $0.line != line }
                    if let match = placed(characters, in: kept, pitch: grid.pitch, vertical: vertical), match.cost == 0 {
                        layout.lines.remove(at: line)
                        layout.cells = rects(match.places)
                        layout.exact = true
                        return layout
                    }
                }
            }
            // Nearly: the squares are still where the characters are, give or take one.
            let squares = grid.cells.count, count = characters.count
            if squares > 0, abs(squares - count) <= max(1, count / 6) {
                layout.cells = rects((0..<count).map { index in
                    let square = grid.cells[min(squares - 1, index * squares / count)]
                    return Place(across: square.across, from: square.from, to: square.to)
                })
                return layout
            }
        }
        // Lettering that isn't on a grid (Latin letters, a hand-drawn title), or text that was
        // read differently from what's drawn: the glyphs by the gaps between them.
        let byGaps = cellsByGaps(ink: ink, lines: layout.lines, count: characters.count)
        layout.cells = byGaps.cells
        layout.exact = byGaps.exact
        return layout
    }

    /// A square of the grid: where it is across the block, and its ink along the line.
    struct Square {
        var line: Int
        var across: ClosedRange<Int>
        var from: CGFloat, to: CGFloat
    }

    /// A character's place: a square or a share of one (or of a few together).
    struct Place {
        var across: ClosedRange<Int>
        var from: CGFloat, to: CGFloat
        var part = 0, parts = 1
    }

    /// The grid the lines are set on: one pitch for the whole block (the same lettering), each
    /// line starting where its own first character does. The pitch and the starts are the ones
    /// whose cuts between squares cross the least ink. `crossing` is how much of a line's
    /// thickness the cuts still cross on average (0: every cut is in a gap).
    static func grid(_ lines: [Line], size: Int, in ink: Ink) -> (cells: [Square], crossing: Double, pitch: Double)? {
        let unit = Double(size)
        let profiles: [[Int]] = lines.map { line in
            line.along.map { l in line.across.reduce(0) { $0 + (ink.isInk($1, l) ? 1 : 0) } }
        }
        /// The least ink a cut near `position` crosses, as a share of the line's thickness.
        func crossing(_ line: Int, at position: Double, reach: Int) -> (ink: Double, at: Int) {
            let profile = profiles[line], l0 = lines[line].along.lowerBound
            let middle = Int(position.rounded()) - l0
            var best = (ink: Double.infinity, at: middle + l0)
            for offset in -reach...reach {
                let index = middle + offset
                guard profile.indices.contains(index) else { continue }
                let value = Double(profile[index]) / Double(lines[line].across.count)
                if value < best.ink || (value == best.ink && abs(offset) < abs(best.at - l0 - middle)) { best = (value, index + l0) }
            }
            return best.ink == .infinity ? (0, middle + l0) : best
        }
        /// A line's best start for a pitch: its cuts' ink in all, their number, and the start.
        func fit(_ line: Int, pitch: Double) -> (ink: Double, cuts: Int, start: Double, cost: Double) {
            let l0 = Double(lines[line].along.lowerBound), l1 = Double(lines[line].along.upperBound + 1)
            let reach = max(1, Int(pitch * 0.06))
            var best = (ink: 0.0, cuts: 0, start: l0, cost: Double.infinity)
            var start = l0 - pitch * 0.5
            while start <= l0 {
                let squares = max(1, Int(((l1 - start - pitch * 0.15) / pitch).rounded(.up)))
                var total = 0.0
                for cut in 1..<max(squares, 1) { total += crossing(line, at: start + pitch * Double(cut), reach: reach).ink }
                // Among starts that are as clean, the one nearest the first ink (a glyph nearly
                // fills its square).
                let cost = total / Double(max(squares - 1, 1)) + 0.03 * abs(start - (l0 - pitch * 0.05)) / pitch
                if cost < best.cost { best = (total, squares - 1, start, cost) }
                start += 1
            }
            return best
        }
        var best: (pitch: Double, starts: [Double], cost: Double, crossing: Double)?
        var pitch = unit * 0.7
        while pitch <= unit * 1.4 {
            let fits = lines.indices.map { fit($0, pitch: pitch) }
            let cuts = fits.reduce(0) { $0 + $1.cuts }
            let crossed = fits.reduce(0) { $0 + $1.ink } / Double(max(cuts, 1))
            let starts = fits.reduce(0) { $0 + ($1.cost - $1.ink / Double(max($1.cuts, 1))) } / Double(lines.count)
            let cost = crossed + starts + 0.1 * abs(pitch - unit * 1.05) / unit
            if cost < (best?.cost ?? .infinity) { best = (pitch, fits.map(\.start), cost, crossed) }
            pitch += max(0.5, unit * 0.01)
        }
        guard let best else { return nil }
        var cells: [Square] = []
        for (index, line) in lines.enumerated() {
            let l0 = line.along.lowerBound, l1 = line.along.upperBound + 1
            let start = best.starts[index]
            let squares = max(1, Int(((Double(l1) - start - best.pitch * 0.15) / best.pitch).rounded(.up)))
            var from = l0
            for square in 1...squares {
                let to = square == squares ? l1 : min(l1, max(from, crossing(index, at: start + best.pitch * Double(square), reach: max(1, Int(best.pitch * 0.1))).at))
                // The square's own ink; one with none is a space.
                let profile = profiles[index]
                if from < to, let first = (from..<to).first(where: { profile[$0 - l0] > 0 }), let last = (from..<to).last(where: { profile[$0 - l0] > 0 }) {
                    cells.append(Square(line: index, across: line.across, from: CGFloat(first), to: CGFloat(last + 1)))
                }
                from = to
            }
        }
        return (cells, best.crossing, best.pitch)
    }

    /// The text's characters matched to the grid's squares. Most take a square each; a few are
    /// set otherwise: a row of dots is drawn as … in a square (or two), and ！？ or two digits
    /// share one. Nil when the text and the squares can't be matched, so one was misread.
    static func placed(_ characters: [Character], in squares: [Square], pitch: Double, vertical: Bool) -> (places: [Place], cost: Int)? {
        // Units of the text, each with the numbers of squares it may take (likeliest first).
        struct Unit {
            var count: Int
            /// The numbers of squares it may take, and what each costs (0: as usually drawn).
            var squares: [(take: Int, cost: Int)]
            var sideBySide = false
            var dots = false
        }
        func isDash(_ character: Character) -> Bool { "ー―—─〜～".contains(character) }
        func isDot(_ character: Character) -> Bool { "．.・…‥".contains(character) }
        func isMark(_ character: Character) -> Bool { "！？!?".contains(character) }
        func isDigit(_ character: Character) -> Bool { character.isNumber && (character.isASCII || ("０"..."９").contains(character)) }
        var units: [Unit] = []
        var index = 0
        while index < characters.count {
            var end = index + 1
            if isDot(characters[index]) {
                while end < characters.count, isDot(characters[end]) { end += 1 }
                let count = end - index
                // Three dots to a square is how … is drawn; a dot to a square is the other way.
                let few = Int((Double(count) / 3).rounded(.up))
                units.append(Unit(count: count, squares: (few...count).map { ($0, $0 == few || $0 == count ? 0 : $0 == few + 1 ? 1 : 2) }, dots: true))
            } else if vertical, isMark(characters[index]), end < characters.count, isMark(characters[end]) {
                end += 1
                units.append(Unit(count: 2, squares: [(1, 0), (2, 0)], sideBySide: true))
            } else if vertical, isDigit(characters[index]), end < characters.count, isDigit(characters[end]),
                      end + 1 >= characters.count || !isDigit(characters[end + 1]) {
                end += 1
                units.append(Unit(count: 2, squares: [(1, 0), (2, 0)], sideBySide: true))
            } else if isDash(characters[index]) {
                // A long dash is often drawn two squares long.
                units.append(Unit(count: 1, squares: [(1, 0), (2, 1)]))
            } else {
                units.append(Unit(count: 1, squares: [(1, 0)]))
            }
            index = end
        }
        // The cheapest way to give every unit its squares and use them all: a unit that would
        // run over the end of a line costs most, an unlikely number of squares a little.
        let total = squares.count
        var cost = [[Int]](repeating: [Int](repeating: .max, count: total + 1), count: units.count + 1)
        var choice = [[Int]](repeating: [Int](repeating: 0, count: total + 1), count: units.count + 1)
        cost[0][0] = 0
        for (number, unit) in units.enumerated() {
            for used in 0...total where cost[number][used] != .max {
                for (take, price) in unit.squares where used + take <= total {
                    let own = squares[used..<(used + take)]
                    if take > 1, own.first?.line != own.last?.line { continue }
                    // A dot to a square is small in its square; … fills its square's length.
                    if unit.dots, take == unit.count, unit.count > 1, own.contains(where: { Double($0.to - $0.from) > pitch * 0.45 }) { continue }
                    let next = cost[number][used] + price
                    if next < cost[number + 1][used + take] {
                        cost[number + 1][used + take] = next
                        choice[number + 1][used + take] = take
                    }
                }
            }
        }
        guard cost[units.count][total] != .max else { return nil }
        var takes = [Int](repeating: 0, count: units.count)
        var used = total
        for number in stride(from: units.count, to: 0, by: -1) {
            takes[number - 1] = choice[number][used]
            used -= choice[number][used]
        }
        var places: [Place] = []
        used = 0
        for (unit, take) in zip(units, takes) {
            let own = squares[used..<(used + take)]
            used += take
            guard let first = own.first, let last = own.last else { return nil }
            if take == unit.count {
                places += own.map { Place(across: $0.across, from: $0.from, to: $0.to) }
            } else if unit.sideBySide {
                places += (0..<unit.count).map { Place(across: first.across, from: first.from, to: first.to, part: $0, parts: unit.count) }
            } else if take > unit.count {
                // A long dash: its squares together.
                places.append(Place(across: first.across, from: first.from, to: last.to))
            } else {
                // Dots: shares of their squares along the line.
                let length = (last.to - first.from) / CGFloat(unit.count)
                places += (0..<unit.count).map { Place(across: first.across, from: first.from + length * CGFloat($0), to: first.from + length * CGFloat($0 + 1)) }
            }
        }
        return places.count == characters.count ? (places, cost[units.count][total]) : nil
    }

    /// Leaves only the lettering's ink: not what runs off the picture's edge (the bubble's
    /// outline, the art around it), and not what's beyond it (screen tone past the outline in
    /// the block's corners), which doesn't touch the paper the lettering is on.
    static func clearEdges(_ mask: inout [Bool], width: Int, height: Int) {
        // The paper: the largest stretch of background.
        var label = [Int32](repeating: 0, count: mask.count)
        var paper: Int32 = 0, most = 0, next: Int32 = 0
        var stack: [Int] = []
        for start in mask.indices where !mask[start] && label[start] == 0 {
            next += 1
            var size = 0
            label[start] = next
            stack.append(start)
            while let index = stack.popLast() {
                size += 1
                let x = index % width
                if x > 0, !mask[index - 1], label[index - 1] == 0 { label[index - 1] = next; stack.append(index - 1) }
                if x < width - 1, !mask[index + 1], label[index + 1] == 0 { label[index + 1] = next; stack.append(index + 1) }
                if index >= width, !mask[index - width], label[index - width] == 0 { label[index - width] = next; stack.append(index - width) }
                if index + width < mask.count, !mask[index + width], label[index + width] == 0 { label[index + width] = next; stack.append(index + width) }
            }
            if size > most { (most, paper) = (size, next) }
        }
        // A few pixels in counts as the edge: scaling the picture softens its outermost rows.
        let band = max(2, min(width, height) / 100)
        var seen = [Bool](repeating: false, count: mask.count)
        var piece: [Int] = []
        for start in mask.indices where mask[start] && !seen[start] {
            piece.removeAll(keepingCapacity: true)
            var onPaper = false, atEdge = false
            seen[start] = true
            stack.append(start)
            while let index = stack.popLast() {
                piece.append(index)
                let x = index % width, y = index / width
                if x < band || y < band || x >= width - band || y >= height - band { atEdge = true }
                for dy in -1...1 where (0..<height).contains(y + dy) {
                    for dx in -1...1 where (0..<width).contains(x + dx) {
                        let other = (y + dy) * width + x + dx
                        if mask[other] {
                            if !seen[other] { seen[other] = true; stack.append(other) }
                        } else if label[other] == paper {
                            onPaper = true
                        }
                    }
                }
            }
            if atEdge || !onPaper {
                for index in piece { mask[index] = false }
            }
        }
    }

    /// True where a pixel is lettering: the darker or lighter side of Otsu's threshold,
    /// whichever is the smaller part of the picture (white text on black counts too).
    static func inkMask(_ gray: [UInt8]) -> [Bool] {
        var histogram = [Int](repeating: 0, count: 256)
        for value in gray { histogram[Int(value)] += 1 }
        let total = gray.count
        let sum = histogram.enumerated().reduce(0.0) { $0 + Double($1.offset * $1.element) }
        var below = 0, sumBelow = 0.0, best = 0.0, threshold = 127
        for level in 0..<256 {
            below += histogram[level]
            guard below > 0, below < total else { continue }
            sumBelow += Double(level * histogram[level])
            let above = total - below
            let difference = sumBelow / Double(below) - (sum - sumBelow) / Double(above)
            let between = Double(below) * Double(above) * difference * difference
            if between > best {
                best = between
                threshold = level
            }
        }
        let dark = gray.reduce(0) { $0 + ($1 <= threshold ? 1 : 0) }
        let inkIsDark = dark * 2 <= total
        return gray.map { ($0 <= threshold) == inkIsDark }
    }
}
