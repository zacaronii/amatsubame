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
