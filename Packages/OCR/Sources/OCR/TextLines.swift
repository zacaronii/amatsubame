import CoreGraphics
import Foundation

/// Finds a block's real lines of lettering (columns of vertical text, rows of horizontal) in
/// its picture, so a tap can be matched to the character under it. The recognizer gives a
/// block's text and box but not where each character sits, and spreading the characters evenly
/// over the box is wrong whenever the columns differ in length or there's furigana.
public enum TextLines {
    /// The lines in reading order (vertical text: right to left), each as a rect in the block's
    /// own unit square (0…1, origin top-left) around its ink. Empty when nothing can be told
    /// apart (then the even spread is used).
    public static func lines(gray: [UInt8], width: Int, height: Int, vertical: Bool) -> [CGRect] {
        guard width > 2, height > 2, gray.count == width * height else { return [] }
        let ink = inkMask(gray)
        // Across the lines: x for vertical text, y for horizontal.
        let across = vertical ? width : height, along = vertical ? height : width
        func isInk(_ a: Int, _ l: Int) -> Bool { vertical ? ink[l * width + a] : ink[a * width + l] }

        var profile = [Int](repeating: 0, count: across)
        for a in 0..<across {
            for l in 0..<along where isInk(a, l) { profile[a] += 1 }
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
        guard !runs.isEmpty else { return [] }

        // A character with gaps inside it (川, い) splits a short line: join runs closer than a
        // fraction of the widest one.
        let widest = runs.map(\.count).max() ?? 1
        var joined: [ClosedRange<Int>] = []
        for run in runs {
            if let last = joined.last, run.lowerBound - last.upperBound - 1 < max(2, widest / 6) {
                joined[joined.count - 1] = last.lowerBound...run.upperBound
            } else {
                joined.append(run)
            }
        }
        // Furigana runs beside its line at about half the size: not a line of its own.
        let thickest = joined.map(\.count).max() ?? 1
        let lines = joined.filter { Double($0.count) >= Double(thickest) * 0.55 }
        guard !lines.isEmpty else { return [] }

        var rects: [CGRect] = []
        for line in lines {
            var first: Int?, last: Int?
            for l in 0..<along where line.contains(where: { isInk($0, l) }) {
                if first == nil { first = l }
                last = l
            }
            guard let first, let last else { continue }
            let a0 = CGFloat(line.lowerBound) / CGFloat(across), a1 = CGFloat(line.upperBound + 1) / CGFloat(across)
            let l0 = CGFloat(first) / CGFloat(along), l1 = CGFloat(last + 1) / CGFloat(along)
            rects.append(vertical ? CGRect(x: a0, y: l0, width: a1 - a0, height: l1 - l0) : CGRect(x: l0, y: a0, width: l1 - l0, height: a1 - a0))
        }
        return vertical ? rects.sorted { $0.midX > $1.midX } : rects.sorted { $0.midY < $1.midY }
    }

    /// Where each of the block's `count` characters sits, in reading order and in the block's
    /// unit square. Every line gets its share of the characters by its length; along the line
    /// the glyphs themselves are found by the gaps between them, so a character's place is the
    /// glyph's own, whatever its width (a narrow 1, a colon, small っ). Empty when it can't be told.
    public static func cells(gray: [UInt8], width: Int, height: Int, vertical: Bool, lines: [CGRect], count: Int) -> [CGRect] {
        guard count > 0, !lines.isEmpty, lines.count <= count, width > 2, height > 2, gray.count == width * height else { return [] }
        let ink = inkMask(gray)
        let across = vertical ? width : height, along = vertical ? height : width
        func isInk(_ a: Int, _ l: Int) -> Bool { vertical ? ink[l * width + a] : ink[a * width + l] }
        let counts = TextLayout.characterCounts(lines.map { vertical ? $0.height : $0.width }, total: count)
        var cells: [CGRect] = []
        for (line, characters) in zip(lines, counts) {
            let a0 = max(0, Int(((vertical ? line.minX : line.minY) * CGFloat(across)).rounded()))
            let a1 = min(across, Int(((vertical ? line.maxX : line.maxY) * CGFloat(across)).rounded()))
            let l0 = max(0, Int(((vertical ? line.minY : line.minX) * CGFloat(along)).rounded()))
            let l1 = min(along, Int(((vertical ? line.maxY : line.maxX) * CGFloat(along)).rounded()))
            guard characters > 0, a1 > a0, l1 > l0 else { return [] }
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
            guard !glyphs.isEmpty else { return [] }
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
                    let window = max(glyph.lowerBound + 1, Int(even) - reach)...min(glyph.upperBound, Int(even) + reach)
                    let thinnest = window.lowerBound <= window.upperBound
                        ? window.min { (profile[$0 - l0], abs(Double($0) - even)) < (profile[$1 - l0], abs(Double($1) - even)) }
                        : nil
                    cuts.append(max(Double(thinnest ?? Int(even)), (cuts.last ?? 0) + 1))
                }
                // To the middle of the gap before the next stretch.
                cuts.append(index < glyphs.count - 1 ? Double(glyph.upperBound + 1 + glyphs[index + 1].lowerBound) / 2 : Double(l1))
            }
            guard cuts.count == characters + 1 else { return [] }
            for index in 0..<characters {
                let from = CGFloat(min(cuts[index], Double(l1))) / CGFloat(along)
                let to = CGFloat(min(max(cuts[index + 1], cuts[index]), Double(l1))) / CGFloat(along)
                cells.append(vertical
                    ? CGRect(x: line.minX, y: from, width: line.width, height: to - from)
                    : CGRect(x: from, y: line.minY, width: to - from, height: line.height))
            }
        }
        return cells.count == count ? cells : []
    }

    /// The lines of a block cut out of its page.
    public static func lines(of box: NormalizedRect, in image: CGImage, vertical: Bool) -> [CGRect] {
        layout(of: box, in: image, vertical: vertical, characterCount: 0).lines
    }

    /// A block's lines and its characters' places (`cells`), from its part of the page.
    public static func layout(of box: NormalizedRect, in image: CGImage, vertical: Bool, characterCount: Int) -> (lines: [CGRect], cells: [CGRect]) {
        let pixels = box.pixels(in: CGSize(width: image.width, height: image.height)).integral
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard pixels.width >= 4, pixels.height >= 4, let crop = image.cropping(to: pixels) else { return ([], []) }
        // Small enough to be quick, large enough to keep the thin gaps between glyphs.
        let scale = min(1, 1000 / max(pixels.width, pixels.height))
        let width = max(4, Int(pixels.width * scale)), height = max(4, Int(pixels.height * scale))
        guard let gray = ImagePreprocessing.grayPixels(crop, width: width, height: height) else { return ([], []) }
        let lines = lines(gray: gray, width: width, height: height, vertical: vertical)
        return (lines, cells(gray: gray, width: width, height: height, vertical: vertical, lines: lines, count: characterCount))
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
