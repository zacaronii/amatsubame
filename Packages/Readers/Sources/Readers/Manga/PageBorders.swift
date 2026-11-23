import CoreGraphics
import Foundation

/// Crop Borders: finds a page's blank margins, white or black, to trim off the screen. The
/// rule is careful: a margin is only lines of one even colour, and a page that would lose too
/// much (a mostly blank page) or has no plain edge (coloured or yellowed paper) isn't cropped.
enum PageBorders {
    /// The long side the page is measured at.
    static let sampleSize = 256
    /// The border is near white or near black…
    static let whiteFrom = 230
    static let blackUpTo = 30
    /// …and the outer two pixels of at least two sides mostly that colour (art may bleed off the others).
    static let ringShare = 0.95
    static let plainSidesNeeded = 2
    static let ringTolerance = 12
    /// A margin line: nearly every pixel near the border colour (JPEG noise and a speck pass).
    static let lineShare = 0.995
    static let lineTolerance = 16
    /// Room given back on each side, as a share of the page.
    static let margin = 0.015
    /// At most this much off one side, and at least this much of each dimension kept.
    static let maxSide = 0.20
    static let minKept = 0.60
    /// Below this on every side, not worth changing the page's size.
    static let minWorthwhile = 0.02

    /// The part of the page to show, normalised (0…1, top-left origin), or nil to show it whole.
    static func detect(_ image: CGImage) -> CGRect? {
        guard let (gray, width, height) = grayscale(image) else { return nil }
        return detect(gray: gray, width: width, height: height)
    }

    static func detect(gray: [UInt8], width: Int, height: Int) -> CGRect? {
        guard width >= 16, height >= 16, gray.count == width * height else { return nil }
        func pixel(_ x: Int, _ y: Int) -> Int { Int(gray[y * width + x]) }

        // The border colour: the median of the outer two pixels all round; then each side's
        // outer two pixels must be mostly that colour to count as plain.
        let edges: [[Int]] = [
            (0..<height).flatMap { y in [pixel(0, y), pixel(1, y)] },
            (0..<height).flatMap { y in [pixel(width - 1, y), pixel(width - 2, y)] },
            (0..<width).flatMap { x in [pixel(x, 0), pixel(x, 1)] },
            (0..<width).flatMap { x in [pixel(x, height - 1), pixel(x, height - 2)] },
        ]
        let ring = edges.flatMap { $0 }
        let border = ring.sorted()[ring.count / 2]
        guard border >= whiteFrom || border <= blackUpTo else { return nil }
        let plain = edges.filter { side in Double(side.filter { abs($0 - border) <= ringTolerance }.count) >= Double(side.count) * ringShare }
        guard plain.count >= plainSidesNeeded else { return nil }

        func isMargin(_ count: Int, _ value: (Int) -> Int) -> Bool {
            var off = 0
            let allowed = Int(Double(count) * (1 - lineShare))
            for index in 0..<count where abs(value(index) - border) > lineTolerance {
                off += 1
                if off > allowed { return false }
            }
            return true
        }
        func row(_ y: Int) -> Bool { isMargin(width) { pixel($0, y) } }
        func column(_ x: Int) -> Bool { isMargin(height) { pixel(x, $0) } }

        var top = 0, bottom = height, left = 0, right = width
        while top < height, row(top) { top += 1 }
        guard top < height else { return nil } // all blank
        while bottom > top, row(bottom - 1) { bottom -= 1 }
        while left < width, column(left) { left += 1 }
        while right > left, column(right - 1) { right -= 1 }

        let w = Double(width), h = Double(height)
        var rect = CGRect(x: max(Double(left) / w - margin, 0), y: max(Double(top) / h - margin, 0), width: 0, height: 0)
        rect.size = CGSize(width: min(Double(right) / w + margin, 1) - rect.minX, height: min(Double(bottom) / h + margin, 1) - rect.minY)
        let sides = [rect.minX, rect.minY, 1 - rect.maxX, 1 - rect.maxY]
        guard sides.allSatisfy({ $0 <= maxSide }), rect.width >= minKept, rect.height >= minKept,
              sides.contains(where: { $0 >= minWorthwhile }) else { return nil }
        return rect
    }

    /// The page in grey at `sampleSize` on its long side.
    private static func grayscale(_ image: CGImage) -> ([UInt8], Int, Int)? {
        let scale = Double(sampleSize) / Double(max(image.width, image.height))
        let width = max(Int(Double(image.width) * min(scale, 1)), 1), height = max(Int(Double(image.height) * min(scale, 1)), 1)
        var gray = [UInt8](repeating: 0, count: width * height)
        let drawn = gray.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? (gray, width, height) : nil
    }

    /// Two facing pages stay level: the same top and bottom (the most either keeps), and the
    /// gutter side whole. `left` is the page drawn on the left.
    static func spread(left: CGRect?, right: CGRect?) -> (left: CGRect, right: CGRect) {
        let whole = CGRect(x: 0, y: 0, width: 1, height: 1)
        let l = left ?? whole, r = right ?? whole
        let top = min(l.minY, r.minY), bottom = max(l.maxY, r.maxY)
        return (CGRect(x: l.minX, y: top, width: 1 - l.minX, height: bottom - top),
                CGRect(x: 0, y: top, width: r.maxX, height: bottom - top))
    }
}
