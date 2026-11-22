import CoreGraphics
import Foundation

/// Estimates which character of a block was tapped. OCR gives each block's text
/// and box but not character positions, so the characters are assumed to fill the
/// box evenly: columns right to left (vertical) or rows top to bottom (horizontal).
public enum TextLayout {
    /// - Parameters:
    ///   - point: the tap, in the same coordinates as `box`.
    /// - Returns: the character index (in `Character`s), clamped to the text.
    public static func characterIndex(of point: CGPoint, in box: CGRect, characterCount count: Int, vertical: Bool) -> Int {
        guard count > 1, box.width > 0, box.height > 0 else { return 0 }
        // Lines across the box, each holding `perLine` characters.
        let across = vertical ? box.width : box.height
        let characterSize = sqrt(box.width * box.height / CGFloat(count))
        let lines = max(1, min(count, Int((across / characterSize).rounded())))
        let perLine = Int((Double(count) / Double(lines)).rounded(.up))

        let lineFraction = vertical ? (box.maxX - point.x) / box.width : (point.y - box.minY) / box.height
        let alongFraction = vertical ? (point.y - box.minY) / box.height : (point.x - box.minX) / box.width
        let line = clamp(Int(lineFraction * CGFloat(lines)), 0, lines - 1)
        let position = clamp(Int(alongFraction * CGFloat(perLine)), 0, perLine - 1)
        return clamp(line * perLine + position, 0, count - 1)
    }

    /// The same with the block's measured lines (`TextLines`, in the block's unit square): the
    /// tap goes to the line it's on (or nearest), and to the character that far along the
    /// line's ink. Each line holds a share of the characters in proportion to its length.
    public static func characterIndex(of point: CGPoint, in box: CGRect, characterCount count: Int, vertical: Bool, lines: [CGRect]) -> Int {
        guard count > 1, box.width > 0, box.height > 0, !lines.isEmpty, lines.count <= count else {
            return characterIndex(of: point, in: box, characterCount: count, vertical: vertical)
        }
        let unit = CGPoint(x: (point.x - box.minX) / box.width, y: (point.y - box.minY) / box.height)
        // Across the lines: x for vertical text.
        func distance(_ line: CGRect) -> CGFloat {
            let low = vertical ? line.minX : line.minY, high = vertical ? line.maxX : line.maxY
            let at = vertical ? unit.x : unit.y
            return at < low ? low - at : at > high ? at - high : 0
        }
        guard let line = lines.indices.min(by: { distance(lines[$0]) < distance(lines[$1]) }) else { return 0 }
        let counts = characterCounts(lines.map { vertical ? $0.height : $0.width }, total: count)
        let rect = lines[line]
        let length = vertical ? rect.height : rect.width
        let fraction = length > 0 ? ((vertical ? unit.y - rect.minY : unit.x - rect.minX) / length) : 0
        let position = clamp(Int(fraction * CGFloat(counts[line])), 0, max(counts[line] - 1, 0))
        return clamp(counts[..<line].reduce(0, +) + position, 0, count - 1)
    }

    /// Where each character is taken to be, in reading order and in the block's unit square,
    /// when its place wasn't measured in the picture (`TextLines.cells`): along the block's
    /// lines by their lengths, or without lines the even spread over the whole box.
    public static func characterRects(characterCount count: Int, vertical: Bool, lines: [CGRect], boxSize: CGSize) -> [CGRect] {
        guard count > 0 else { return [] }
        if !lines.isEmpty, lines.count <= count {
            let counts = characterCounts(lines.map { vertical ? $0.height : $0.width }, total: count)
            return zip(lines, counts).flatMap { line, characters in
                (0..<characters).map { index in
                    let from = CGFloat(index) / CGFloat(characters), size = 1 / CGFloat(characters)
                    return vertical
                        ? CGRect(x: line.minX, y: line.minY + from * line.height, width: line.width, height: size * line.height)
                        : CGRect(x: line.minX + from * line.width, y: line.minY, width: size * line.width, height: line.height)
                }
            }
        }
        guard boxSize.width > 0, boxSize.height > 0 else { return [] }
        let across = vertical ? boxSize.width : boxSize.height
        let characterSize = sqrt(boxSize.width * boxSize.height / CGFloat(count))
        let lineCount = max(1, min(count, Int((across / characterSize).rounded())))
        let perLine = Int((Double(count) / Double(lineCount)).rounded(.up))
        return (0..<count).map { index in
            let line = CGFloat(index / perLine), position = CGFloat(index % perLine)
            let thickness = 1 / CGFloat(lineCount), length = 1 / CGFloat(perLine)
            return vertical
                ? CGRect(x: 1 - (line + 1) * thickness, y: position * length, width: thickness, height: length)
                : CGRect(x: position * length, y: line * thickness, width: length, height: thickness)
        }
    }

    /// The character whose place (`cells`, in the box's unit square) the point is in, or the
    /// nearest one.
    public static func characterIndex(of point: CGPoint, in box: CGRect, cells: [CGRect]) -> Int {
        guard box.width > 0, box.height > 0, !cells.isEmpty else { return 0 }
        let unit = CGPoint(x: (point.x - box.minX) / box.width, y: (point.y - box.minY) / box.height)
        func distance(_ cell: CGRect) -> CGFloat {
            // Measured in the box's own proportions, so "nearest" means nearest on the page.
            let dx = max(cell.minX - unit.x, 0, unit.x - cell.maxX) * box.width
            let dy = max(cell.minY - unit.y, 0, unit.y - cell.maxY) * box.height
            return dx * dx + dy * dy
        }
        return cells.indices.min { distance(cells[$0]) < distance(cells[$1]) } ?? 0
    }

    /// `total` characters shared among lines by their lengths: each at least one, the
    /// remainders going to the lines that came closest to another character.
    public static func characterCounts(_ lengths: [CGFloat], total: Int) -> [Int] {
        let sum = lengths.reduce(0, +)
        guard sum > 0, !lengths.isEmpty else { return lengths.map { _ in 0 } }
        let exact = lengths.map { Double($0 / sum) * Double(total) }
        var counts = exact.map { max(1, Int($0.rounded(.down))) }
        var left = total - counts.reduce(0, +)
        let byRemainder = exact.indices.sorted { exact[$0] - exact[$0].rounded(.down) > exact[$1] - exact[$1].rounded(.down) }
        var turn = 0
        while left != 0, turn < 4 * lengths.count {
            let index = byRemainder[left > 0 ? turn % lengths.count : lengths.count - 1 - turn % lengths.count]
            if left > 0 {
                counts[index] += 1
                left -= 1
            } else if counts[index] > 1 {
                counts[index] -= 1
                left += 1
            }
            turn += 1
        }
        return counts
    }

    private static func clamp(_ value: Int, _ low: Int, _ high: Int) -> Int {
        min(max(value, low), high)
    }
}

/// Whether a block's text runs top to bottom. Manga text is vertical by default; a
/// block of several vertical columns can be as wide as it is tall, so the box shape
/// alone can't tell. Treat a block as horizontal only when it's clearly one wide line
/// or the text is mostly Latin letters and digits (English lettering, signs).
public enum TextOrientation {
    public static func isVertical(pixelSize size: CGSize, text: String) -> Bool {
        if size.width > size.height * 2 { return false }
        let letters = text.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        let latin = letters.filter { (0x30...0x7A).contains($0.value) || (0xFF10...0xFF5A).contains($0.value) }
        if !letters.isEmpty, Double(latin.count) / Double(letters.count) > 0.6 { return false }
        return true
    }
}
