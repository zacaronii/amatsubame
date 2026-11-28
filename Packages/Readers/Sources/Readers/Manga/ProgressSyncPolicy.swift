import Core
import Foundation
import KavitaKit

/// Rules for converting between the page on screen and Kavita's `pageNum`
/// (pages read), and for choosing where to resume.
public enum ProgressSyncPolicy {
    /// Kavita counts pages read: the on-screen index, except that reaching the
    /// last page reports `pages`, which is what marks the chapter read.
    public static func pageNum(forPage page: Int, pages: Int) -> Int {
        LocalReadingProgress.pagesRead(forPage: page, pages: pages)
    }

    /// Where to open a chapter: the newer of this device's and the server's
    /// progress. A finished chapter opens from the start.
    public static func startPage(local: LocalReadingProgress?, server: KavitaServerProgress?, pages: Int, unsent: Bool = false) -> Int {
        startPosition(local: local, server: server, pages: pages, unsent: unsent).page
    }

    /// The page and, for books, the position on it (`bookScrollId`) to resume at, by the one rule
    /// (`LocalReadingProgress.devicesPlaceWins`). A finished chapter opens from the start,
    /// without a position.
    public static func startPosition(
        local: LocalReadingProgress?, server: KavitaServerProgress?, pages: Int, unsent: Bool = false
    ) -> (page: Int, scrollId: String?) {
        guard pages > 0 else { return (0, nil) }
        let pagesRead: Int
        let scrollId: String?
        switch (local, server) {
        case let (local?, server?):
            (pagesRead, scrollId) = LocalReadingProgress.devicesPlaceWins(localAt: local.updatedAt, kavitaAt: server.lastModifiedUtc, unsent: unsent)
                ? (pageNum(forPage: local.page, pages: pages), local.scrollId) : (server.pageNum, server.bookScrollId)
        case let (local?, nil): (pagesRead, scrollId) = (pageNum(forPage: local.page, pages: pages), local.scrollId)
        case let (nil, server?): (pagesRead, scrollId) = server.lastModifiedUtc == nil ? (0, nil) : (server.pageNum, server.bookScrollId)
        case (nil, nil): (pagesRead, scrollId) = (0, nil)
        }
        if pagesRead >= pages { return (0, nil) }
        return (min(max(pagesRead, 0), pages - 1), scrollId)
    }
}
