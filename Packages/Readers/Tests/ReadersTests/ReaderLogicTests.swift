import Core
import CoreGraphics
import CoreTestSupport
import Foundation
import ImageIO
import KavitaKit
@testable import Readers
import Synchronization
import Testing
import UniformTypeIdentifiers

@Suite struct SpreadLayoutTests {
    @Test func singlePagesWithoutSpreads() {
        #expect(SpreadLayout.slots(pageCount: 3, widePages: [], spreads: false, coverAlone: true) == [[0], [1], [2]])
    }

    @Test func coverAloneThenPairs() {
        #expect(SpreadLayout.slots(pageCount: 6, widePages: [], spreads: true, coverAlone: true) == [[0], [1, 2], [3, 4], [5]])
    }

    @Test func pairsFromFirstPageWhenCoverNotAlone() {
        #expect(SpreadLayout.slots(pageCount: 5, widePages: [], spreads: true, coverAlone: false) == [[0, 1], [2, 3], [4]])
    }

    @Test func widePagesStandAloneAndBreakPairs() {
        // Page 4 is a scanned two-page spread: 3 can't pair across it.
        #expect(SpreadLayout.slots(pageCount: 8, widePages: [4], spreads: true, coverAlone: true)
            == [[0], [1, 2], [3], [4], [5, 6], [7]])
    }

    @Test func emptyChapter() {
        #expect(SpreadLayout.slots(pageCount: 0, widePages: [], spreads: true, coverAlone: true).isEmpty)
    }

    @Test func slotLookup() {
        let slots = SpreadLayout.slots(pageCount: 6, widePages: [], spreads: true, coverAlone: true)
        #expect(SpreadLayout.slotIndex(containing: 0, in: slots) == 0)
        #expect(SpreadLayout.slotIndex(containing: 2, in: slots) == 1)
        #expect(SpreadLayout.slotIndex(containing: 5, in: slots) == 3)
        #expect(SpreadLayout.slotIndex(containing: 99, in: slots) == 3)
    }
}

@Suite struct ProgressSyncPolicyTests {
    let t = Date(timeIntervalSince1970: 1_800_000_000)

    func local(_ page: Int, at date: Date) -> LocalReadingProgress {
        LocalReadingProgress(chapterId: 1, seriesId: 1, volumeId: 1, libraryId: 1, page: page, pages: 20, updatedAt: date)
    }

    func server(_ pageNum: Int, at date: Date?) -> KavitaServerProgress {
        KavitaServerProgress(chapterId: 1, pageNum: pageNum, lastModifiedUtc: date)
    }

    @Test func pageNumMatchesKavitaSemantics() {
        #expect(ProgressSyncPolicy.pageNum(forPage: 0, pages: 20) == 0)
        #expect(ProgressSyncPolicy.pageNum(forPage: 5, pages: 20) == 5)
        #expect(ProgressSyncPolicy.pageNum(forPage: 18, pages: 20) == 18)
        #expect(ProgressSyncPolicy.pageNum(forPage: 19, pages: 20) == 20, "last page marks the chapter read")
    }

    @Test func newerProgressWins() {
        #expect(ProgressSyncPolicy.startPage(local: local(3, at: t), server: server(9, at: t + 60), pages: 20) == 9)
        #expect(ProgressSyncPolicy.startPage(local: local(12, at: t + 60), server: server(9, at: t), pages: 20) == 12)
    }

    @Test func eitherSideAlone() {
        #expect(ProgressSyncPolicy.startPage(local: local(4, at: t), server: nil, pages: 20) == 4)
        #expect(ProgressSyncPolicy.startPage(local: nil, server: server(7, at: t), pages: 20) == 7)
        #expect(ProgressSyncPolicy.startPage(local: nil, server: server(0, at: nil), pages: 20) == 0)
        #expect(ProgressSyncPolicy.startPage(local: local(4, at: t), server: server(0, at: nil), pages: 20) == 4)
    }

    @Test func finishedChapterStartsOver() {
        #expect(ProgressSyncPolicy.startPage(local: nil, server: server(20, at: t), pages: 20) == 0)
        #expect(ProgressSyncPolicy.startPage(local: local(19, at: t), server: nil, pages: 20) == 0)
    }
}

@Suite @MainActor struct ReadingProgressRecorderTests {
    let database: AppDatabase
    let outbox: OutboxStore
    let progress: ReadingProgressStore
    let chapter = ReaderChapter(chapterId: 206, volumeId: 206, seriesId: 4, libraryId: 1, pages: 10, title: "Volume 1", seriesTitle: "The Lantern Keeper")

    init() throws {
        database = try AppDatabase.inMemory()
        outbox = OutboxStore(database: database)
        progress = ReadingProgressStore(database: database)
    }

    func recorder(debounce: Duration = .seconds(60), syncs: @escaping @MainActor () -> Void = {}) -> ReadingProgressRecorder {
        ReadingProgressRecorder(chapter: chapter, progressStore: progress, outbox: outbox, syncNow: syncs, debounce: debounce)
    }

    func queuedPayloads() throws -> [KavitaProgressPayload] {
        try outbox.jobs(states: [.pending]).map { try $0.decodePayload(KavitaProgressPayload.self) }
    }

    @Test func savesLocallyAtOnceAndQueuesOnFlush() throws {
        var syncs = 0
        let recorder = recorder { syncs += 1 }
        recorder.start(at: 0)
        recorder.record(page: 3)
        recorder.record(page: 4)
        #expect(try progress.progress(chapterId: 206)?.page == 4)
        #expect(try queuedPayloads().isEmpty)

        recorder.flush()
        #expect(try queuedPayloads() == [KavitaProgressPayload(volumeId: 206, chapterId: 206, pageNum: 4, seriesId: 4, libraryId: 1)])
        #expect(syncs == 1)

        recorder.flush()
        #expect(syncs == 1, "nothing new to send")
    }

    @Test func openingAChapterRecordsNothing() throws {
        let recorder = recorder()
        recorder.start(at: 7)
        recorder.record(page: 7)
        recorder.flush()
        #expect(try progress.progress(chapterId: 206) == nil)
        #expect(try queuedPayloads().isEmpty)
    }

    @Test func lastPageQueuesChapterAsRead() throws {
        let recorder = recorder()
        recorder.start(at: 0)
        recorder.record(page: 9)
        recorder.flush()
        #expect(try queuedPayloads().first?.pageNum == 10)
    }

    @Test func repeatedFlushesCollapseToOneJob() throws {
        let recorder = recorder()
        recorder.start(at: 0)
        for page in 1...5 {
            recorder.record(page: page)
            recorder.flush()
        }
        #expect(try queuedPayloads().map(\.pageNum) == [5])
    }

    @Test func debounceQueuesAfterPause() async throws {
        let recorder = recorder(debounce: .milliseconds(50))
        recorder.start(at: 0)
        recorder.record(page: 2)
        try await Task.sleep(for: .milliseconds(300))
        #expect(try queuedPayloads().map(\.pageNum) == [2])
    }
}

/// A page source that counts requests and can be switched offline.
final class FakePageSource: MangaPageSource {
    let requests = Mutex<[Int]>([])
    let offline = Mutex(false)

    func dimensions(chapterId: Int) async throws -> [KavitaPageDimension] {
        if offline.withLock({ $0 }) { throw ConnectionError.unreachable("offline") }
        return [KavitaPageDimension(pageNumber: 0, width: 10, height: 20, isWide: false)]
    }

    func pageData(chapterId: Int, page: Int) async throws -> Data {
        if offline.withLock({ $0 }) { throw ConnectionError.unreachable("offline") }
        requests.withLock { $0.append(page) }
        try await Task.sleep(for: .milliseconds(20))
        return Data("page\(page)".utf8)
    }

    func serverProgress(chapterId: Int) async throws -> KavitaServerProgress {
        KavitaServerProgress(chapterId: chapterId, pageNum: 0, lastModifiedUtc: nil)
    }
}

@Suite struct MangaPageRepositoryTests {
    let source = FakePageSource()
    let repository: MangaPageRepository

    init() throws {
        let cache = PageCacheStore(database: try AppDatabase.inMemory(),
                                   directory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        let source = source
        repository = MangaPageRepository(cache: cache) { source }
    }

    @Test func concurrentRequestsShareOneDownloadAndCacheServesOffline() async throws {
        async let a = repository.pageData(chapterId: 1, page: 3)
        async let b = repository.pageData(chapterId: 1, page: 3)
        #expect(try await [a, b] == [Data("page3".utf8), Data("page3".utf8)])
        #expect(source.requests.withLock { $0 } == [3])

        source.offline.withLock { $0 = true }
        #expect(try await repository.pageData(chapterId: 1, page: 3) == Data("page3".utf8))
        await #expect(throws: ConnectionError.self) { try await repository.pageData(chapterId: 1, page: 4) }
    }

    @Test func dimensionsAreCachedForOfflineLayout() async throws {
        #expect(try await repository.dimensions(chapterId: 1).count == 1)
        source.offline.withLock { $0 = true }
        #expect(try await repository.dimensions(chapterId: 1).count == 1)
    }

    @Test func unconfiguredSourceFails() async throws {
        let cache = PageCacheStore(database: try AppDatabase.inMemory(), directory: FileManager.default.temporaryDirectory)
        let repository = MangaPageRepository(cache: cache) { nil }
        await #expect(throws: MangaPageError.notConfigured) { try await repository.pageData(chapterId: 1, page: 0) }
    }

    @Test func decodesAndDownsamples() async throws {
        let context = CGContext(data: nil, width: 400, height: 600, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)

        let image = try await MangaPageRepository.decodeImage(data as Data, maxPixelSize: 300)
        #expect(image.height == 300)
        #expect(image.width == 200)
        await #expect(throws: MangaPageError.undecodable) { try await MangaPageRepository.decodeImage(Data("x".utf8), maxPixelSize: 10) }
    }
}

@Suite struct MangaMiningContextTests {
    @Test func miscInfoNamesSeriesChapterAndPage() {
        let chapter = ReaderChapter(chapterId: 1, volumeId: 2, seriesId: 3, libraryId: 4, pages: 20, title: "Chapter 5", seriesTitle: "雨の日の図書室")
        #expect(MangaMiningContext.miscInfo(chapter: chapter, page: 11) == "雨の日の図書室 — Chapter 5, p. 12")
        var untitled = chapter
        untitled.title = ""
        #expect(MangaMiningContext.miscInfo(chapter: untitled, page: 0) == "雨の日の図書室, p. 1")
    }
}

@Suite struct PopupPlacementTests {
    @Test func popupOpensAwayFromTheNearerEdge() {
        #expect(PopupPlacement.arrowEdge(for: CGRect(x: 900, y: 100, width: 80, height: 200), width: 1200) == .trailing)
        #expect(PopupPlacement.arrowEdge(for: CGRect(x: 100, y: 100, width: 80, height: 200), width: 1200) == .leading)
        #expect(PopupPlacement.arrowEdge(for: .zero, width: 0) == .leading)
    }
}
