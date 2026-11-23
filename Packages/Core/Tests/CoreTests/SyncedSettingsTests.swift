@testable import Core
import Foundation
import GRDB
import Testing

/// Settings kept the same with Sync with iCloud: two databases and one folder (no iCloud).
@Suite struct SyncedSettingsTests {
    let folder = FileManager.default.temporaryDirectory.appending(path: "SyncedSettingsTests-\(UUID().uuidString)")
    let start = Date(timeIntervalSince1970: 1_795_651_200)

    final class Clock: @unchecked Sendable {
        var now: Date
        init(_ now: Date) { self.now = now }
    }

    struct Device {
        let id: String
        let app: String
        let database = try! AppDatabase.inMemory()
        let clock: Clock
        let collections: [any SyncedCollection]

        @discardableResult
        func sync(_ folder: URL, at date: Date) throws -> Bool {
            clock.now = date
            return try RecordSync(database: database, app: app, collections: collections, now: { [clock] in clock.now })
                .sync(root: folder, device: id)
        }

        func kavita(_ url: String) throws {
            try database.writer.write {
                try $0.execute(sql: "INSERT OR REPLACE INTO serverAccount (kind, baseURL) VALUES ('kavita', ?)", arguments: [url])
            }
        }
    }

    func yomu(_ id: String) -> Device {
        Device(id: id, app: "yomu", clock: Clock(start), collections: [TableCollection.mangaReaderSettings, TableCollection.bookReaderSettings])
    }

    @Test func readerSettingsFollowTheSeriesOnTheSameServer() throws {
        let a = yomu("aaaa"), b = yomu("bbbb"), c = yomu("cccc")
        try a.kavita("https://kavita.example/")
        try b.kavita("https://KAVITA.example")
        try c.kavita("https://other.example")
        var manga = MangaReaderSettings()
        manga.direction = .leftToRight
        manga.cropsBorders = true
        try MangaReaderSettingsStore(database: a.database).save(manga, seriesId: 12)
        var all = MangaReaderSettings()
        all.mode = .longStrip
        try MangaReaderSettingsStore(database: a.database).saveAsDefault(all)
        var book = BookReaderSettings()
        book.font = .gothic
        try BookReaderSettingsStore(database: a.database).save(book, seriesId: 7)
        try a.sync(folder, at: start)
        #expect(try b.sync(folder, at: start.addingTimeInterval(60)))
        #expect(try MangaReaderSettingsStore(database: b.database).settings(seriesId: 12) == manga, "the same server (address case and slash aside)")
        #expect(try MangaReaderSettingsStore(database: b.database).settings(seriesId: 99) == all, "Use for All")
        #expect(try BookReaderSettingsStore(database: b.database).settings(seriesId: 7).font == .gothic)
        try c.sync(folder, at: start.addingTimeInterval(60))
        #expect(try MangaReaderSettingsStore(database: c.database).settings(seriesId: 12) == all,
                "another server's series 12 isn't this one: only Use for All arrives")
        // Nothing new on b: applied settings aren't its own edits.
        #expect(try !b.sync(folder, at: start.addingTimeInterval(120)))
        let own = try b.database.reader.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM syncRecord WHERE device = 'bbbb'") }
        #expect(own == 0)
    }

    @Test func miruKeepsItsStreamQualityPerDevice() throws {
        let a = Device(id: "aaaa", app: "miru", clock: Clock(start), collections: [TableCollection.playerSettings])
        let b = Device(id: "bbbb", app: "miru", clock: Clock(start), collections: [TableCollection.playerSettings])
        try b.database.writer.write { db in
            var settings = PlayerSettings()
            settings.maxStreamBitrate = 2_000_000
            try settings.save(db)
        }
        try a.database.writer.write { db in
            var settings = PlayerSettings()
            settings.speed = 1.25
            settings.subtitleScale = 1.2
            settings.concealsSubtitles = true
            settings.maxStreamBitrate = 8_000_000
            try settings.save(db)
        }
        try b.sync(folder, at: start)
        try a.sync(folder, at: start.addingTimeInterval(60))
        try b.sync(folder, at: start.addingTimeInterval(120))
        let onB = try #require(try b.database.reader.read { try PlayerSettings.fetchOne($0) })
        #expect(onB.speed == 1.25 && onB.subtitleScale == 1.2 && onB.concealsSubtitles)
        #expect(onB.maxStreamBitrate == 2_000_000, "b's own")
    }

    @Test func kikuSettingsAndShowsButNotTheWatchOrHiddenLibraries() throws {
        let a = Device(id: "aaaa", app: "kiku", clock: Clock(start), collections: [TableCollection.listenSettings, TableCollection.showListenSettings])
        let b = Device(id: "bbbb", app: "kiku", clock: Clock(start), collections: [TableCollection.listenSettings, TableCollection.showListenSettings])
        try ListenSettings(skipBackward: 10, skipForward: 45, speed: 1.1, hiddenLibraries: ["lib-a"], watchLiveText: true).save(a.database)
        try ListenSettings(hiddenLibraries: ["lib-b"]).save(b.database)
        try ShowListenSetting(itemId: "show-1", speed: 1.5, skipStart: 20).save(a.database)
        try b.sync(folder, at: start)
        try a.sync(folder, at: start.addingTimeInterval(60))
        try b.sync(folder, at: start.addingTimeInterval(120))
        let onB = ListenSettings.load(b.database)
        #expect(onB.skipBackward == 10 && onB.skipForward == 45 && onB.speed == 1.1)
        #expect(onB.hiddenLibraries == ["lib-b"] && !onB.watchLiveText, "b's own")
        #expect(ShowListenSetting.load(b.database, itemId: "show-1") == ShowListenSetting(itemId: "show-1", speed: 1.5, skipStart: 20))
        // Back to plain on a (the row goes): gone on b too.
        try ShowListenSetting(itemId: "show-1").save(a.database)
        try a.sync(folder, at: start.addingTimeInterval(180))
        try b.sync(folder, at: start.addingTimeInterval(240))
        let rows = try b.database.reader.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM showListenSetting") }
        #expect(rows == 0)
    }
}
