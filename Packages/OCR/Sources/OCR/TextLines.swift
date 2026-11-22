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

    /// The lines of a block cut out of its page.
    public static func lines(of box: NormalizedRect, in image: CGImage, vertical: Bool) -> [CGRect] {
        let pixels = box.pixels(in: CGSize(width: image.width, height: image.height)).integral
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard pixels.width >= 4, pixels.height >= 4, let crop = image.cropping(to: pixels) else { return [] }
        // Small enough to be quick, large enough to keep the gaps between lines.
        let scale = min(1, 240 / max(pixels.width, pixels.height))
        let width = max(4, Int(pixels.width * scale)), height = max(4, Int(pixels.height * scale))
        guard let gray = ImagePreprocessing.grayPixels(crop, width: width, height: height) else { return [] }
        return lines(gray: gray, width: width, height: height, vertical: vertical)
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
