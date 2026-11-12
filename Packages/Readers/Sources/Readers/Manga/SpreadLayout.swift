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
}
