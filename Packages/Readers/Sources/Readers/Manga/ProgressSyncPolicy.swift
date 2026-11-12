import Core
import Foundation
import KavitaKit

/// Rules for converting between the page on screen and Kavita's `pageNum`
/// (pages read), and for choosing where to resume.
public enum ProgressSyncPolicy {
    /// Kavita counts pages read: the on-screen index, except that reaching the
    /// last page reports `pages`, which is what marks the chapter read.
    public static func pageNum(forPage page: Int, pages: Int) -> Int {
        guard pages > 0 else { return 0 }
        return page >= pages - 1 ? pages : max(page, 0)
    }

    /// Where to open a chapter: the newer of this device's and the server's
    /// progress. A finished chapter opens from the start.
    public static func startPage(local: LocalReadingProgress?, server: KavitaServerProgress?, pages: Int) -> Int {
        startPosition(local: local, server: server, pages: pages).page
    }

    /// The page and, for books, the position on it (`bookScrollId`) to resume at.
    /// A finished chapter opens from the start, without a position.
    public static func startPosition(
        local: LocalReadingProgress?, server: KavitaServerProgress?, pages: Int
    ) -> (page: Int, scrollId: String?) {
        guard pages > 0 else { return (0, nil) }
        let localRead = local.map { (pageNum(forPage: $0.page, pages: pages), $0.updatedAt, $0.scrollId) }
        let serverRead = server.flatMap { progress in progress.lastModifiedUtc.map { (progress.pageNum, $0, progress.bookScrollId) } }

        let pagesRead: Int
        let scrollId: String?
        switch (localRead, serverRead) {
        case let (local?, server?): (pagesRead, scrollId) = server.1 > local.1 ? (server.0, server.2) : (local.0, local.2)
        case let (local?, nil): (pagesRead, scrollId) = (local.0, local.2)
        case let (nil, server?): (pagesRead, scrollId) = (server.0, server.2)
        case (nil, nil): (pagesRead, scrollId) = (0, nil)
        }
        if pagesRead >= pages { return (0, nil) }
        return (min(max(pagesRead, 0), pages - 1), scrollId)
    }
}
