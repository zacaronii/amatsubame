import Foundation

/// A series' volumes split the way Kavita's UI shows them, plus the order the
/// reader follows when moving to the next chapter.
public struct KavitaSeriesContents: Codable, Equatable, Hashable, Sendable {
    public var volumes: [KavitaVolume]
    public var looseChapters: [KavitaChapter]
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
