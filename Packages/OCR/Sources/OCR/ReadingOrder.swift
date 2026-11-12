import Foundation

/// Orders text blocks the way a Japanese manga page is read: top to bottom in
/// bands, and right to left within a band. Text in the same speech bubble stays
/// together (columns right to left).
public enum ReadingOrder {
    public struct Item: Equatable, Sendable {
        public var box: NormalizedRect
        /// Index of the bubble containing this text, if any.
        public var bubble: Int?

        public init(box: NormalizedRect, bubble: Int? = nil) {
            self.box = box
            self.bubble = bubble
        }
    }

    /// The bubble that contains most (≥ 70%) of a text box, if any.
    public static func containingBubble(of box: NormalizedRect, in bubbles: [NormalizedRect]) -> Int? {
        bubbles.indices
            .filter { box.area > 0 && bubbles[$0].intersection(box) / box.area >= 0.7 }
            .min { bubbles[$0].area < bubbles[$1].area }
    }

    /// Returns the indices of `items` in reading order.
    public static func order(_ items: [Item]) -> [Int] {
        // Units: one per bubble (its texts ordered right to left), plus each free text.
        var units: [(box: NormalizedRect, members: [Int])] = []
        var bubbleUnits: [Int: Int] = [:]
        for (index, item) in items.enumerated() {
            if let bubble = item.bubble, let unit = bubbleUnits[bubble] {
                units[unit].members.append(index)
                units[unit].box = NormalizedRect(units[unit].box.cgRect.union(item.box.cgRect))
            } else {
                if let bubble = item.bubble { bubbleUnits[bubble] = units.count }
                units.append((item.box, [index]))
            }
        }
        for unit in units.indices {
            units[unit].members.sort { items[$0].box.maxX > items[$1].box.maxX }
        }

        // Bands: units whose vertical spans overlap by at least half the smaller height.
        var bands: [(minY: Double, maxY: Double, units: [Int])] = []
        for unit in units.indices.sorted(by: { units[$0].box.y < units[$1].box.y }) {
            let box = units[unit].box
            if let band = bands.indices.last, overlapRatio(bands[band].minY, bands[band].maxY, box.y, box.maxY) >= 0.5 {
                bands[band].units.append(unit)
                bands[band].minY = min(bands[band].minY, box.y)
                bands[band].maxY = max(bands[band].maxY, box.maxY)
            } else {
                bands.append((box.y, box.maxY, [unit]))
            }
        }
        return bands.flatMap { band in
            band.units.sorted { units[$0].box.maxX > units[$1].box.maxX }.flatMap { units[$0].members }
        }
    }

    private static func overlapRatio(_ a0: Double, _ a1: Double, _ b0: Double, _ b1: Double) -> Double {
        let overlap = min(a1, b1) - max(a0, b0)
        let smaller = min(a1 - a0, b1 - b0)
        return smaller > 0 ? max(overlap, 0) / smaller : 0
    }
}
