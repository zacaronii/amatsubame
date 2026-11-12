import Foundation
import KavitaKit
import Testing

@Suite struct AutoDownloadPlannerTests {
    /// A series of `count` one-chapter volumes of 100 pages; chapter ids are 10, 11, 12…
    static func series(_ count: Int, read: [Int] = []) -> KavitaSeriesContents {
        KavitaSeriesContents(volumes: (0..<count).map { index in
            let pagesRead = index < read.count ? read[index] : 0
            let chapter = KavitaChapter(id: 10 + index, volumeId: 100 + index, number: "0", sortOrder: 0, pages: 100, pagesRead: pagesRead)
            return KavitaVolume(id: 100 + index, seriesId: 1, name: "\(index + 1)", number: Double(index + 1), pages: 100,
                                pagesRead: pagesRead, chapters: [chapter])
        })
    }

    @Test func keepsTheCurrentVolumeAndTheNextOnes() {
        // Volume 1 finished, volume 2 half read: keep 2, 3 and 4.
        let contents = Self.series(6, read: [100, 50])
        #expect(AutoDownloadPlanner.chaptersToKeep(contents, ahead: 2, local: [:]).map(\.id) == [11, 12, 13])
    }

    @Test func nothingBeforeTheSeriesIsStartedOrWhenOff() {
        #expect(AutoDownloadPlanner.chaptersToKeep(Self.series(4), ahead: 2, local: [:]).isEmpty)
        #expect(AutoDownloadPlanner.chaptersToKeep(Self.series(4, read: [10]), ahead: 0, local: [:]).isEmpty)
    }

    @Test func stopsAtTheEndAndWhenAllRead() {
        #expect(AutoDownloadPlanner.chaptersToKeep(Self.series(3, read: [100, 5]), ahead: 5, local: [:]).map(\.id) == [11, 12])
        #expect(AutoDownloadPlanner.chaptersToKeep(Self.series(2, read: [100, 100]), ahead: 1, local: [:]).isEmpty)
    }

    @Test func thisDevicesProgressCountsBeforeTheServerHasIt() {
        // The server still thinks volume 1 is unread; this device finished it.
        let contents = Self.series(4)
        #expect(AutoDownloadPlanner.chaptersToKeep(contents, ahead: 1, local: [10: 100]).map(\.id) == [11, 12])
        #expect(AutoDownloadPlanner.finishedDownloads([10, 11], in: contents, local: [10: 100], openChapterId: nil) == [10])
    }

    @Test func chapterSeriesCountChaptersAhead() {
        let chapters = (0..<5).map { KavitaChapter(id: 50 + $0, volumeId: 9, number: "\($0 + 1)", sortOrder: Double($0 + 1), pages: 20,
                                                   pagesRead: $0 == 0 ? 3 : 0) }
        let contents = KavitaSeriesContents(volumes: [
            KavitaVolume(id: 9, seriesId: 1, name: "", number: KavitaVolume.looseLeafNumber, pages: 100, pagesRead: 3, chapters: chapters),
        ])
        #expect(AutoDownloadPlanner.chaptersToKeep(contents, ahead: 2, local: [:]).map(\.id) == [50, 51, 52])
    }

    @Test func finishedDownloadsSkipTheOpenVolumeAndUnknownOnes() {
        let contents = Self.series(4, read: [100, 100, 30])
        #expect(AutoDownloadPlanner.finishedDownloads([10, 11, 12, 99], in: contents, local: [:], openChapterId: 11) == [10])
    }
}
