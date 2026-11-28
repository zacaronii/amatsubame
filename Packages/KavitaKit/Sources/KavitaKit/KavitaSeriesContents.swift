import Core
import Foundation

/// A series' volumes split the way Kavita's UI shows them, plus the order the
/// reader follows when moving to the next chapter.
public struct KavitaSeriesContents: Codable, Equatable, Hashable, Sendable {
    public var volumes: [KavitaVolume]
    public var looseChapters: [KavitaChapter]

    /// The same with exactly these pages read for these chapters (Mark as Read / Unread, at once).
    public func settingPagesRead(_ pagesRead: [Int: Int]) -> KavitaSeriesContents {
        func set(_ chapter: KavitaChapter) -> KavitaChapter {
            var chapter = chapter
            if let pages = pagesRead[chapter.id] { chapter.pagesRead = min(pages, chapter.pages) }
            return chapter
        }
        var contents = self
        contents.volumes = volumes.map { volume in
            var volume = volume
            volume.chapters = volume.chapters.map(set)
            if !volume.chapters.isEmpty { volume.pagesRead = volume.chapters.reduce(0) { $0 + $1.pagesRead } }
            return volume
        }
        contents.looseChapters = looseChapters.map(set)
        return contents
    }

    /// The same with this device's reading where it wins (`LocalReadingProgress.devicesPlaceWins`):
    /// `pagesRead` by chapter id (Kavita's count of pages read), `updated` when this device's
    /// place was saved, `unsent` the chapters with a change not sent yet.
    public func readingFurther(_ pagesRead: [Int: Int], updated: [Int: Date] = [:], unsent: Set<Int> = []) -> KavitaSeriesContents {
        guard !pagesRead.isEmpty else { return self }
        func further(_ chapter: KavitaChapter) -> KavitaChapter {
            var chapter = chapter
            guard let local = pagesRead[chapter.id] else { return chapter }
            chapter.pagesRead = LocalReadingProgress.pagesRead(kavita: chapter.pagesRead, kavitaAt: chapter.lastReadingProgressUtc,
                                                               local: local, localAt: updated[chapter.id], pages: chapter.pages,
                                                               unsent: unsent.contains(chapter.id))
            return chapter
        }
        var contents = self
        contents.volumes = volumes.map { volume in
            var volume = volume
            volume.chapters = volume.chapters.map(further)
            if !volume.chapters.isEmpty { volume.pagesRead = volume.chapters.reduce(0) { $0 + $1.pagesRead } }
            return volume
        }
        contents.looseChapters = looseChapters.map(further)
        return contents
    }
    public var specials: [KavitaChapter]

    public init(volumes allVolumes: [KavitaVolume]) {
        volumes = allVolumes
            .filter { !$0.isLooseLeaf && !$0.isSpecials }
            .sorted { $0.number < $1.number }
            .map { volume in
                var volume = volume
                volume.chapters.sort { $0.sortOrder < $1.sortOrder }
                return volume
            }
        looseChapters = allVolumes.filter(\.isLooseLeaf).flatMap(\.chapters).sorted { $0.sortOrder < $1.sortOrder }
        specials = allVolumes.filter(\.isSpecials).flatMap(\.chapters).sorted { $0.sortOrder < $1.sortOrder }
    }

    /// Volumes in order, then loose chapters. Specials are read on their own.
    public var readingOrder: [KavitaChapter] {
        volumes.flatMap(\.chapters) + looseChapters
    }

    public func chapter(after chapterId: Int) -> KavitaChapter? {
        let order = readingOrder
        guard let index = order.firstIndex(where: { $0.id == chapterId }), index + 1 < order.count else { return nil }
        return order[index + 1]
    }

    /// The first chapter that isn't fully read, falling back to the first one.
    public var continueChapter: KavitaChapter? {
        let order = readingOrder
        return order.first { !$0.isRead } ?? order.first ?? specials.first
    }

    public var isEmpty: Bool { volumes.isEmpty && looseChapters.isEmpty && specials.isEmpty }
}
