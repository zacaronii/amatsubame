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
        // c skipped series 12 (not its server): that isn't a deletion, so a and b keep it.
        try c.sync(folder, at: start.addingTimeInterval(90))
        try a.sync(folder, at: start.addingTimeInterval(100))
        #expect(try MangaReaderSettingsStore(database: a.database).settings(seriesId: 12) == manga, "not deleted by the other server's device")
        // Nothing new on b: applied settings aren't its own edits.
        try b.sync(folder, at: start.addingTimeInterval(110))
        #expect(try MangaReaderSettingsStore(database: b.database).settings(seriesId: 12) == manga)
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

/// Kiku's marks and notes between two devices.
@Suite struct SyncedMarksTests {
    let folder = FileManager.default.temporaryDirectory.appending(path: "SyncedMarksTests-\(UUID().uuidString)")
    let start = Date(timeIntervalSince1970: 1_795_651_200)

    func device(_ id: String) -> SyncedSettingsTests.Device {
        SyncedSettingsTests.Device(id: id, app: "kiku", clock: SyncedSettingsTests.Clock(start), collections: [TableCollection.audioMarks])
    }

    func marks(_ d: SyncedSettingsTests.Device, at date: Date) -> AudioMarkStore {
        AudioMarkStore(database: d.database, now: { date })
    }

    @Test func marksNotesMiningAndClearReachTheOtherDevice() throws {
        let a = device("aaaa"), b = device("bbbb")
        let made = try marks(a, at: start).add(AudioMark(itemId: "show", episodeId: "ep", showTitle: "番組", episodeTitle: "#1", time: 42,
                                                          createdAt: start, source: .headphones))
        try a.sync(folder, at: start)
        try b.sync(folder, at: start.addingTimeInterval(10))
        var onB = try #require(try marks(b, at: start).marks().first)
        #expect(onB.uuid == made.uuid && onB.time == 42 && onB.source == .headphones)
        #expect(onB.id != nil, "a row of b's own")

        // Notes: a writes, then b edits later; b's note wins on both.
        try marks(a, at: start).setNote(try #require(made.id), "a's note")
        try a.sync(folder, at: start.addingTimeInterval(20))
        try b.sync(folder, at: start.addingTimeInterval(30))
        onB = try #require(try marks(b, at: start).marks().first)
        #expect(onB.note == "a's note")
        try marks(b, at: start).setNote(try #require(onB.id), "b's later note")
        try b.sync(folder, at: start.addingTimeInterval(40))
        try a.sync(folder, at: start.addingTimeInterval(50))
        #expect(try marks(a, at: start).marks().first?.note == "b's later note")

        // Mined on b: a shows it mined too, without b's card job.
        try marks(b, at: start.addingTimeInterval(60)).setMined(try #require(onB.id), word: "雑談", jobId: 7)
        try b.sync(folder, at: start.addingTimeInterval(60))
        try a.sync(folder, at: start.addingTimeInterval(70))
        let onA = try #require(try marks(a, at: start.addingTimeInterval(70)).marks().first)
        #expect(onA.minedWord == "雑談" && onA.isMined && onA.minedJobId == nil)

        // Cleared on a: gone on b, and it doesn't come back.
        try marks(a, at: start).remove(try #require(onA.id))
        try a.sync(folder, at: start.addingTimeInterval(80))
        try b.sync(folder, at: start.addingTimeInterval(90))
        #expect(try marks(b, at: start.addingTimeInterval(90)).marks().isEmpty)
        try a.sync(folder, at: start.addingTimeInterval(100))
        #expect(try marks(a, at: start.addingTimeInterval(100)).marks().isEmpty)
    }

    /// A mined mark goes a day after mining on each device; the deletion syncs like a Clear.
    @Test func prunedMinedMarksStayGone() throws {
        let a = device("aaaa"), b = device("bbbb")
        let made = try marks(a, at: start).add(AudioMark(itemId: "show", episodeId: "ep", showTitle: "番組", episodeTitle: "#1", time: 5,
                                                          createdAt: start, source: .player))
        try marks(a, at: start).setMined(try #require(made.id), word: "語", jobId: 1)
        try a.sync(folder, at: start)
        try b.sync(folder, at: start.addingTimeInterval(10))
        let later = start.addingTimeInterval(AudioMarkStore.minedKeptFor + 60)
        try marks(a, at: later).pruneMined()
        try a.sync(folder, at: later)
        try b.sync(folder, at: later.addingTimeInterval(10))
        let rows = try b.database.reader.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM audioMark") }
        #expect(rows == 0)
    }

    /// Marks made before this version get an id of their own, different for each.
    @Test func existingMarksGetIDs() throws {
        let database = try AppDatabase.inMemory()
        let store = AudioMarkStore(database: database)
        let first = try store.add(AudioMark(itemId: "s", episodeId: "e", showTitle: "t", episodeTitle: "e", time: 1, createdAt: start, source: .player))
        let second = try store.add(AudioMark(itemId: "s", episodeId: "e", showTitle: "t", episodeTitle: "e", time: 2, createdAt: start, source: .player))
        #expect(first.uuid != second.uuid && !first.uuid.isEmpty)
    }
}
