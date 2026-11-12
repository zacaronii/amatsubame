import Foundation

/// Everything the reader needs to open one Kavita chapter and report progress for it.
public struct ReaderChapter: Codable, Hashable, Identifiable, Sendable {
    public var chapterId: Int
    public var volumeId: Int
    public var seriesId: Int
    public var libraryId: Int
    public var pages: Int
    public var title: String
    public var seriesTitle: String

    public var id: Int { chapterId }

    public init(chapterId: Int, volumeId: Int, seriesId: Int, libraryId: Int, pages: Int, title: String, seriesTitle: String) {
        self.chapterId = chapterId
        self.volumeId = volumeId
        self.seriesId = seriesId
        self.libraryId = libraryId
        self.pages = pages
        self.title = title
        self.seriesTitle = seriesTitle
    }
}
