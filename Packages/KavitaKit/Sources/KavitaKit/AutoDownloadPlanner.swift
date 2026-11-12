import Foundation

/// Decides what automatic downloads keep on the device for a series being read: the volume
/// being read plus a number after it, and which downloaded volumes are finished. Progress is
/// Kavita's, raised by this device's own (which may not have reached the server yet).
public enum AutoDownloadPlanner {
    /// Pages read per chapter on this device (the page on screen + 1), by chapter id.
    public typealias LocalProgress = [Int: Int]

    public static func pagesRead(_ chapter: KavitaChapter, local: LocalProgress) -> Int {
        max(chapter.pagesRead, local[chapter.id] ?? 0)
    }

    public static func isFinished(_ chapter: KavitaChapter, local: LocalProgress) -> Bool {
        chapter.pages > 0 && pagesRead(chapter, local: local) >= chapter.pages
    }

    /// Whether the series has been started at all (any page read).
    public static func isStarted(_ contents: KavitaSeriesContents, local: LocalProgress) -> Bool {
        (contents.readingOrder + contents.specials).contains { pagesRead($0, local: local) > 0 }
    }

    /// The first unfinished chapter in reading order and the `ahead` after it. Empty when
    /// `ahead` is 0, the series isn't started, or everything is read.
    public static func chaptersToKeep(_ contents: KavitaSeriesContents, ahead: Int, local: LocalProgress) -> [KavitaChapter] {
        guard ahead > 0, isStarted(contents, local: local) else { return [] }
        let order = contents.readingOrder
        guard let current = order.firstIndex(where: { !isFinished($0, local: local) }) else { return [] }
        return Array(order[current..<min(current + 1 + ahead, order.count)])
    }

    /// Downloaded chapters (by id) that are finished, except the one open in the reader.
    public static func finishedDownloads(_ downloaded: [Int], in contents: KavitaSeriesContents, local: LocalProgress,
                                         openChapterId: Int?) -> [Int] {
        let chapters = Dictionary((contents.readingOrder + contents.specials).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return downloaded.filter { id in
            guard id != openChapterId, let chapter = chapters[id] else { return false }
            return isFinished(chapter, local: local)
        }
    }
}
