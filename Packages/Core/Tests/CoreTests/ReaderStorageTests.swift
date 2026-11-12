import Core
import Foundation
import Testing

@Suite struct PageCacheStoreTests {
    let clock = TestClock()
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)

    func makeStore(limit: Int) throws -> PageCacheStore {
        let clock = clock
        return PageCacheStore(database: try AppDatabase.inMemory(), directory: directory, limitBytes: limit, now: { clock.now })
    }

    @Test func storesAndReadsBack() throws {
        let store = try makeStore(limit: 1000)
        let key = PageCacheKey(chapterId: 1, page: 0)
        #expect(store.data(for: key) == nil)
        try store.store(Data("page".utf8), for: key)
        #expect(store.data(for: key) == Data("page".utf8))
        #expect(store.contains(key))
        #expect(try store.totalBytes() == 4)
    }

    @Test func evictsLeastRecentlyUsedFirst() throws {
        let store = try makeStore(limit: 20)
        let a = PageCacheKey(chapterId: 1, page: 0), b = PageCacheKey(chapterId: 1, page: 1), c = PageCacheKey(chapterId: 1, page: 2)
        try store.store(Data(count: 10), for: a)
        clock.advance(1)
        try store.store(Data(count: 10), for: b)
        clock.advance(1)
        _ = store.data(for: a) // a is now more recent than b
        clock.advance(1)
        try store.store(Data(count: 10), for: c)

        #expect(store.contains(a))
        #expect(!store.contains(b))
        #expect(store.contains(c))
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "1-1.bin").path()))
    }

    @Test func pinnedEntriesSurviveEvictionAndClear() throws {
        let store = try makeStore(limit: 10)
        let pinned = PageCacheKey(chapterId: 2, page: 0)
        try store.store(Data(count: 50), for: pinned, pinned: true)
        try store.store(Data(count: 8), for: PageCacheKey(chapterId: 3, page: 0))
        #expect(store.contains(pinned))
        try store.clear()
        #expect(store.contains(pinned))
        #expect(try store.totalBytes() == 50)
    }

    @Test func missingFileDropsIndexRow() throws {
        let store = try makeStore(limit: 1000)
        let key = PageCacheKey(chapterId: 1, page: 0)
        try store.store(Data("x".utf8), for: key)
        try FileManager.default.removeItem(at: directory.appending(path: "1-0.bin"))
        #expect(store.data(for: key) == nil)
        #expect(!store.contains(key))
    }
}

@Suite struct ReadingProgressStoreTests {
    @Test func recentlyReadReturnsLatestChapterPerSeries() throws {
        let store = ReadingProgressStore(database: try AppDatabase.inMemory())
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        try store.save(LocalReadingProgress(chapterId: 1, seriesId: 10, volumeId: 1, libraryId: 1, page: 5, pages: 20, updatedAt: t))
        try store.save(LocalReadingProgress(chapterId: 2, seriesId: 10, volumeId: 2, libraryId: 1, page: 3, pages: 20, updatedAt: t + 10))
        try store.save(LocalReadingProgress(chapterId: 3, seriesId: 11, volumeId: 3, libraryId: 1, page: 1, pages: 20, updatedAt: t + 5))
        #expect(try store.recentlyRead().map(\.chapterId) == [2, 3])
        #expect(try store.progress(chapterId: 1)?.page == 5)
    }

    /// A book's place keeps the reader's character count.
    @Test func bookProgressKeepsItsCharacters() throws {
        let store = ReadingProgressStore(database: try AppDatabase.inMemory())
        try store.save(LocalReadingProgress(chapterId: 1, seriesId: 10, volumeId: 1, libraryId: 1, page: 7, pages: 20,
                                            updatedAt: .now, scrollId: "//p[3]", characters: 15_618))
        #expect(try store.progress(chapterId: 1)?.characters == 15_618)
    }
}

@Suite struct MangaReaderSettingsStoreTests {
    @Test func seriesSettingsFallBackToGlobalThenDefault() throws {
        let store = MangaReaderSettingsStore(database: try AppDatabase.inMemory())
        #expect(try store.settings(seriesId: 1) == .default)

        var global = MangaReaderSettings()
        global.mode = .longStrip
        try store.saveAsDefault(global)
        #expect(try store.settings(seriesId: 1).mode == .longStrip)

        var series = MangaReaderSettings()
        series.direction = .leftToRight
        try store.save(series, seriesId: 1)
        #expect(try store.settings(seriesId: 1) == series)
        #expect(try store.settings(seriesId: 2) == global)
    }
}

@Suite struct MangaReaderSettingsDecodingTests {
    @Test func settingsFromOlderVersionsKeepNewDefaults() throws {
        let old = Data(#"{"mode":"longStrip","direction":"leftToRight","spreads":"off","coverAlone":false,"stripWidth":0.8}"#.utf8)
        let settings = try JSONDecoder().decode(MangaReaderSettings.self, from: old)
        #expect(settings.mode == .longStrip)
        #expect(settings.stripWidth == 0.8)
        #expect(settings.showsTextBoxes == false)
        #expect(settings.ocrAhead == 3)
    }
}

@Suite struct DownloadedPagesTests {
    func cache(limit: Int) throws -> PageCacheStore {
        PageCacheStore(database: try AppDatabase.inMemory(),
                       directory: URL.temporaryDirectory.appending(path: "PinTest-\(UUID().uuidString)"), limitBytes: limit)
    }

    @Test func pinnedChaptersSurviveEvictionAndClear() throws {
        let cache = try cache(limit: 10)
        try cache.store(Data(count: 8), for: PageCacheKey(chapterId: 1, page: 0))
        try cache.setPinned(chapterId: 1, true)
        // Re-storing a downloaded page keeps it downloaded.
        try cache.store(Data(count: 8), for: PageCacheKey(chapterId: 1, page: 0))
        try cache.store(Data(count: 8), for: PageCacheKey(chapterId: 2, page: 0))
        try cache.store(Data(count: 8), for: PageCacheKey(chapterId: 3, page: 0))
        #expect(cache.contains(PageCacheKey(chapterId: 1, page: 0)))
        #expect(!cache.contains(PageCacheKey(chapterId: 2, page: 0)))
        #expect(try cache.unpinnedBytes() == 8)
        try cache.clear()
        #expect(cache.contains(PageCacheKey(chapterId: 1, page: 0)))
        #expect(try cache.cachedPages(chapterId: 1) == [0])
        #expect(try cache.bytes(chapterId: 1) == 8)
    }

    @Test func unpinAndRemove() throws {
        let cache = try cache(limit: 100)
        try cache.store(Data(count: 8), for: PageCacheKey(chapterId: 1, page: 0), pinned: true)
        try cache.store(Data(count: 4), for: PageCacheKey.dimensions(chapterId: 1), pinned: true)
        try cache.setPinned(chapterId: 1, false)
        #expect(try cache.unpinnedBytes() == 12)
        try cache.remove(chapterId: 1)
        #expect(try cache.totalBytes() == 0)
        #expect(cache.data(for: PageCacheKey(chapterId: 1, page: 0)) == nil)
    }
}
