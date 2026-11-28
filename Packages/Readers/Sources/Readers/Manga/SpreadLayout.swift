import Foundation

/// Groups pages into what the paged reader shows at once. Without spreads every
/// page stands alone; with spreads, consecutive pages pair up except the cover
/// (when `coverAlone`) and wide pages, which are already two-page scans.
/// Pages within a spread are in reading order; the view mirrors them for RTL.
public enum SpreadLayout {
    public static func slots(pageCount: Int, widePages: Set<Int>, spreads: Bool, coverAlone: Bool) -> [[Int]] {
        guard pageCount > 0 else { return [] }
        guard spreads else { return (0..<pageCount).map { [$0] } }
        var slots: [[Int]] = []
        var pending: Int?
        for page in 0..<pageCount {
            if widePages.contains(page) || (page == 0 && coverAlone) {
                if let single = pending { slots.append([single]) }
                pending = nil
                slots.append([page])
            } else if let first = pending {
                slots.append([first, page])
                pending = nil
            } else {
                pending = page
            }
        }
        if let single = pending { slots.append([single]) }
        return slots
    }

    public static func slotIndex(containing page: Int, in slots: [[Int]]) -> Int {
        slots.firstIndex { $0.contains(page) } ?? (page <= 0 ? 0 : max(slots.count - 1, 0))
    }

    /// The same, with a wide page standing alone shown as two halves when `splitsWide` (a
    /// portrait reader): first then second, in reading order (the view puts the first on the
    /// right in a right-to-left book).
    public static func readerSlots(pageCount: Int, widePages: Set<Int>, spreads: Bool, coverAlone: Bool, splitsWide: Bool) -> [ReaderSlot] {
        slots(pageCount: pageCount, widePages: widePages, spreads: spreads, coverAlone: coverAlone).flatMap { pages -> [ReaderSlot] in
            guard splitsWide, pages.count == 1, widePages.contains(pages[0]) else { return [ReaderSlot(pages: pages)] }
            return [ReaderSlot(pages: pages, half: .first), ReaderSlot(pages: pages, half: .second)]
        }
    }

    /// The slot to show a page in: its first half when it's split (opening, the slider,
    /// Continue).
    public static func slotIndex(containing page: Int, in slots: [ReaderSlot]) -> Int {
        slots.firstIndex { $0.pages.contains(page) } ?? (page <= 0 ? 0 : max(slots.count - 1, 0))
    }

    /// Moving between the two halves of the same page (not a page move).
    public static func isHalfMove(from old: ReaderSlot?, to new: ReaderSlot?) -> Bool {
        guard let old, let new, old.half != nil, new.half != nil else { return false }
        return old.pages == new.pages && old.half != new.half
    }

    /// After the slots change (a resize, the toggle): the slot showing the same page, and the
    /// same half of it when it's still split; else the page's first slot.
    public static func slotIndex(keeping old: ReaderSlot?, page: Int, in slots: [ReaderSlot]) -> Int {
        if let old, let half = old.half, old.pages == [page],
           let same = slots.firstIndex(where: { $0.pages == [page] && $0.half == half }) {
            return same
        }
        return slotIndex(containing: page, in: slots)
    }
}

/// Which part of a split wide page a slot shows, in reading order.
public enum PageHalf: Hashable, Sendable {
    case first, second
}

/// What the paged reader shows at once: one page, two (a spread), or half of a wide page.
public struct ReaderSlot: Hashable, Sendable {
    public var pages: [Int]
    public var half: PageHalf?

    public init(pages: [Int], half: PageHalf? = nil) {
        self.pages = pages
        self.half = half
    }

    /// The part of the page shown, as a fraction of its width from the page's left edge, for a
    /// book read `rightToLeft` or not (the first half is the right one in a right-to-left book).
    public func visibleRange(rightToLeft: Bool) -> ClosedRange<Double> {
        switch half {
        case nil: 0...1
        case .first?: rightToLeft ? 0.5...1 : 0...0.5
        case .second?: rightToLeft ? 0...0.5 : 0.5...1
        }
    }
}
