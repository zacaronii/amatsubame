import CoreGraphics
import Foundation

/// A rectangle in page coordinates normalized to 0…1 (origin top-left), so it
/// survives the page being shown at any size.
public struct NormalizedRect: Codable, Equatable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public init(_ rect: CGRect) {
        self.init(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
    }

    public var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var area: Double { width * height }

    /// The rect in pixels for an image of the given size.
    public func pixels(in size: CGSize) -> CGRect {
        CGRect(x: x * size.width, y: y * size.height, width: width * size.width, height: height * size.height)
    }

    func intersection(_ other: NormalizedRect) -> Double {
        let overlap = cgRect.intersection(other.cgRect)
        return overlap.isNull ? 0 : overlap.width * overlap.height
    }

    func intersectionOverUnion(_ other: NormalizedRect) -> Double {
        let shared = intersection(other)
        let union = area + other.area - shared
        return union > 0 ? shared / union : 0
    }
}

/// One recognized text block. Shaped like a mokuro block so `.mokuro` files can
/// supply the same data later (phase 7).
public struct OCRBlock: Codable, Equatable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// Text inside a speech bubble.
        case bubbleText
        /// Text outside bubbles (narration, signs, sound effects).
        case freeText
        /// A region the reader drew by hand.
        case manual
    }

    public var box: NormalizedRect
    public var text: String
    public var vertical: Bool
    public var kind: Kind
    public var score: Double

    public init(box: NormalizedRect, text: String, vertical: Bool, kind: Kind, score: Double = 1) {
        self.box = box
        self.text = text
        self.vertical = vertical
        self.kind = kind
        self.score = score
    }
}

/// A page's text blocks in reading order.
public struct OCRPage: Codable, Equatable, Sendable {
    public var imageWidth: Int
    public var imageHeight: Int
    public var blocks: [OCRBlock]

    public init(imageWidth: Int, imageHeight: Int, blocks: [OCRBlock]) {
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.blocks = blocks
    }

    /// The topmost block containing a normalized point.
    public func block(at point: CGPoint) -> OCRBlock? {
        blocks.last { $0.box.cgRect.contains(point) }
    }
}

/// How long each OCR stage took, for the debug timings overlay.
public struct OCRTimings: Equatable, Sendable {
    public var detection: Duration = .zero
    public var recognition: Duration = .zero
    public var blocks = 0

    public init() {}

    public var total: Duration { detection + recognition }
}
