import Core
import Foundation
import Testing

@Suite struct DownloadStoreTests {
    let day = Date(timeIntervalSince1970: 1_793_400_000)

    func record(_ key: String, series: String = "S", at offset: TimeInterval = 0) -> DownloadRecord {
        DownloadRecord(kind: .jellyfinItem, itemKey: key, seriesKey: series, seriesTitle: "Show \(series)", title: "Ep \(key)",
                       createdAt: day.addingTimeInterval(offset))
    }

    @Test func oneDownloadPerItemAndRequeueOnRetry() throws {
        let store = DownloadStore(database: try AppDatabase.inMemory())
        let first = try store.enqueue(record("E1"))
        let again = try store.enqueue(record("E1"))
        #expect(first.id == again.id)
        try store.setState(try #require(first.id), .failed, error: "offline")
        let retried = try store.enqueue(record("E1"))
        #expect(retried.state == .queued && retried.error == nil)
        #expect(try store.all(kind: .jellyfinItem).count == 1)
        // Other kinds don't collide.
        var chapter = record("E1")
        chapter.kind = .kavitaChapter
        try store.enqueue(chapter)
        #expect(try store.all(kind: .kavitaChapter).count == 1)
    }

    @Test func extraChangesWithoutTouchingTheState() throws {
        let store = DownloadStore(database: try AppDatabase.inMemory())
        let id = try #require(try store.enqueue(record("A")).id)
        try store.finish(id, file: nil, bytes: 100, extra: Data("pending".utf8))
        try store.setExtra(id, Data("read".utf8))
        let current = try #require(try store.download(id: id))
        #expect(current.state == .done && current.bytesTotal == 100 && current.extra == Data("read".utf8))
    }

    @Test func progressFinishAndQueueOrder() throws {
        let store = DownloadStore(database: try AppDatabase.inMemory(), now: { Date(timeIntervalSince1970: 1_793_500_000) })
        let a = try store.enqueue(record("A", at: 0))
        let b = try store.enqueue(record("B", at: 10))
        #expect(try store.nextQueued(kind: .jellyfinItem)?.itemKey == "A")
        let id = try #require(a.id)
        try store.setProgress(id, done: 500, total: 2000)
        var current = try #require(try store.download(id: id))
        #expect(current.state == .downloading && current.fraction == 0.25)
        #expect(try store.nextQueued(kind: .jellyfinItem)?.itemKey == "B")
        try store.finish(id, file: "A.mkv", bytes: 2000)
        current = try #require(try store.download(id: id))
        #expect(current.state == .done && current.file == "A.mkv" && current.completedAt != nil)
        // Late progress callbacks don't undo a finished download.
        try store.setProgress(id, done: 10, total: nil)
        #expect(try store.download(id: id)?.state == .done)
        #expect(try store.totalBytes(kind: .jellyfinItem) == 2000)

        try store.setState(try #require(b.id), .downloading)
        try store.requeueInterrupted()
        #expect(try store.download(id: try #require(b.id))?.state == .queued)
        try store.remove(id)
        #expect(try store.download(id: id) == nil)
    }

    @Test func groupsBySeriesNewestFirst() {
        let groups = DownloadStore.grouped([record("1", series: "X", at: 0), record("2", series: "Y", at: 5), record("3", series: "X", at: 9)])
        #expect(groups.map(\.seriesKey) == ["X", "Y"])
        #expect(groups[0].downloads.map(\.itemKey) == ["1", "3"])
        // A newer volume finishing doesn't move its series.
        let later = DownloadStore.grouped([record("1", series: "X", at: 0), record("2", series: "Y", at: 5), record("4", series: "Y", at: 20)])
        #expect(later.map(\.seriesKey) == ["X", "Y"])
    }

    @Test func settingsDefaultToWiFiOnly() throws {
        let database = try AppDatabase.inMemory()
        #expect(DownloadSettings.load(database) == DownloadSettings(allowsCellular: false, readsDownloadedPages: true))
        try DownloadSettings(allowsCellular: true).save(database)
        #expect(DownloadSettings.load(database).allowsCellular)
    }

    @Test func autoDownloadSettingsPerLibrary() throws {
        let store = AutoDownloadSettingsStore(database: try AppDatabase.inMemory())
        #expect(try store.setting(libraryId: 3) == AutoDownloadSetting(libraryId: 3))
        try store.save(AutoDownloadSetting(libraryId: 3, ahead: 2, removesFinished: true))
        try store.save(AutoDownloadSetting(libraryId: 4, ahead: 1))
        #expect(try store.all().mapValues(\.ahead) == [3: 2, 4: 1])
        #expect(try store.setting(libraryId: 3).removesFinished)
        // Turning both off forgets the library.
        try store.save(AutoDownloadSetting(libraryId: 4))
        #expect(try store.all().keys.sorted() == [3])
    }

    @Test func failedDownloadsGoBackInLine() throws {
        let store = DownloadStore(database: try AppDatabase.inMemory())
        let id = try #require(try store.enqueue(record("A")).id)
        try store.setState(id, .failed, error: "The request timed out.")
        try store.requeueFailed(kind: .jellyfinItem)
        let current = try #require(try store.download(id: id))
        #expect(current.state == .queued && current.error == nil)
    }
}
