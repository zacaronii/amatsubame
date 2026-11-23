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

/// The rest of the audit's list: hidden libraries, pairings, Jimaku timing, the kechimochi
/// address, the popup's settings.
@Suite struct SyncedRestTests {
    let folder = FileManager.default.temporaryDirectory.appending(path: "SyncedRestTests-\(UUID().uuidString)")
    let start = Date(timeIntervalSince1970: 1_795_651_200)

    func device(_ id: String, _ app: String, _ collections: [any SyncedCollection]) -> SyncedSettingsTests.Device {
        SyncedSettingsTests.Device(id: id, app: app, clock: SyncedSettingsTests.Clock(start), collections: collections)
    }

    func server(_ d: SyncedSettingsTests.Device, _ kind: String, _ url: String) throws {
        try d.database.writer.write {
            try $0.execute(sql: "INSERT OR REPLACE INTO serverAccount (kind, baseURL) VALUES (?, ?)", arguments: [kind, url])
        }
    }

    func count(_ d: SyncedSettingsTests.Device, _ sql: String) throws -> Int {
        try d.database.reader.read { try Int.fetchOne($0, sql: sql) ?? 0 }
    }

    @Test func hiddenLibrariesFollowTheirServer() throws {
        let collections: [any SyncedCollection] = [TableCollection.hiddenLibraries]
        let a = device("aaaa", "yomu", collections), b = device("bbbb", "yomu", collections), c = device("cccc", "yomu", collections)
        try server(a, "kavita", "https://k.example"); try server(b, "kavita", "https://k.example"); try server(c, "kavita", "https://other.example")
        try a.database.writer.write { try $0.execute(sql: "INSERT INTO hiddenLibrary (libraryId) VALUES (3), (5)") }
        try a.sync(folder, at: start)
        try b.sync(folder, at: start.addingTimeInterval(10))
        try c.sync(folder, at: start.addingTimeInterval(10))
        #expect(try count(b, "SELECT COUNT(*) FROM hiddenLibrary") == 2)
        #expect(try count(c, "SELECT COUNT(*) FROM hiddenLibrary") == 0, "another server's library 3 isn't this one's")
        // Shown again on b: shown on a.
        try b.database.writer.write { try $0.execute(sql: "DELETE FROM hiddenLibrary WHERE libraryId = 5") }
        try b.sync(folder, at: start.addingTimeInterval(20))
        try c.sync(folder, at: start.addingTimeInterval(25))
        try a.sync(folder, at: start.addingTimeInterval(30))
        #expect(try count(a, "SELECT COUNT(*) FROM hiddenLibrary") == 1)
    }

    @Test func miruLibraryChoicesAndKikuHiddenLibraries() throws {
        let miru: [any SyncedCollection] = [TableCollection.hiddenJellyfinLibraries, TableCollection.japaneseOnlyJellyfinLibraries]
        let a = device("aaaa", "miru", miru), b = device("bbbb", "miru", miru)
        try server(a, "jellyfin", "https://j.example"); try server(b, "jellyfin", "https://j.example")
        try a.database.writer.write {
            try $0.execute(sql: "INSERT INTO hiddenJellyfinLibrary (libraryId) VALUES ('music')")
            try $0.execute(sql: "INSERT INTO japaneseOnlyJellyfinLibrary (libraryId) VALUES ('anime')")
        }
        try a.sync(folder, at: start)
        try b.sync(folder, at: start.addingTimeInterval(10))
        #expect(try count(b, "SELECT COUNT(*) FROM hiddenJellyfinLibrary WHERE libraryId = 'music'") == 1)
        #expect(try count(b, "SELECT COUNT(*) FROM japaneseOnlyJellyfinLibrary WHERE libraryId = 'anime'") == 1)

        let kiku: [any SyncedCollection] = [TableCollection.listenSettings, TableCollection.kikuHiddenLibraries]
        let c = device("cccc", "kiku", kiku), d = device("dddd", "kiku", kiku)
        try server(c, "audiobookshelf", "https://a.example"); try server(d, "audiobookshelf", "https://a.example")
        try ListenSettings(speed: 1.2, hiddenLibraries: ["english"], watchLiveText: true).save(c.database)
        try c.sync(folder, at: start)
        try d.sync(folder, at: start.addingTimeInterval(10))
        let onD = ListenSettings.load(d.database)
        #expect(onD.hiddenLibraries == ["english"], "\(onD.hiddenLibraries)")
        #expect(onD.speed == 1.2, "\(onD.speed)")
        #expect(!onD.watchLiveText)
    }

    @Test func pairingsSyncTheChoiceAndDropAnOldAlignment() throws {
        let collections: [any SyncedCollection] = [ReadAlongPairCollection()]
        let a = device("aaaa", "yomu", collections), b = device("bbbb", "yomu", collections)
        try server(a, "kavita", "https://k.example"); try server(b, "kavita", "https://k.example")
        try a.database.writer.write { try ReadAlongPair(chapterId: 9, itemId: "book-1", bookTitle: "本", createdAt: start).save($0) }
        try a.sync(folder, at: start)
        try b.sync(folder, at: start.addingTimeInterval(10))
        var onB = try #require(try b.database.reader.read { try ReadAlongPair.fetchOne($0, key: 9) })
        #expect(onB.itemId == "book-1" && onB.cues == nil, "the choice, aligned again here")
        // b aligns it; that's b's own and isn't sent.
        onB.cues = Data([1, 2]); onB.alignedAt = start
        try b.database.writer.write { try onB.save($0) }
        #expect(try !b.sync(folder, at: start.addingTimeInterval(20)))
        // Paired with another audiobook on a: b's alignment for the old one goes.
        try a.database.writer.write { try $0.execute(sql: "UPDATE readAlongPair SET itemId = 'book-2' WHERE chapterId = 9") }
        try a.sync(folder, at: start.addingTimeInterval(30))
        try b.sync(folder, at: start.addingTimeInterval(40))
        onB = try #require(try b.database.reader.read { try ReadAlongPair.fetchOne($0, key: 9) })
        #expect(onB.itemId == "book-2" && onB.cues == nil && onB.alignedAt == nil)
    }

    @Test func subtitleTimingOnlyForTheSameFileAndNeverRemovesOne() throws {
        let collections: [any SyncedCollection] = [SubtitleTimingCollection()]
        let a = device("aaaa", "miru", collections), b = device("bbbb", "miru", collections), c = device("cccc", "miru", collections)
        for d in [a, b, c] { try server(d, "jellyfin", "https://j.example") }
        func subtitle(_ d: SyncedSettingsTests.Device, file: String, offset: Double) throws {
            try d.database.writer.write { db in
                try LocalSubtitle(itemId: "ep-1", source: "jimaku", fileName: file, format: "srt", data: Data("1".utf8), offset: offset, savedAt: start).save(db)
            }
        }
        func offset(_ d: SyncedSettingsTests.Device) throws -> Double? {
            try d.database.reader.read { try Double.fetchOne($0, sql: "SELECT offset FROM localSubtitle WHERE itemId = 'ep-1'") }
        }
        try subtitle(b, file: "ep1.srt", offset: 0)
        try subtitle(c, file: "other.srt", offset: 0)
        try b.sync(folder, at: start); try c.sync(folder, at: start)
        try subtitle(a, file: "ep1.srt", offset: 1.5)
        try a.sync(folder, at: start.addingTimeInterval(10))
        try b.sync(folder, at: start.addingTimeInterval(20))
        try c.sync(folder, at: start.addingTimeInterval(20))
        #expect(try offset(b) == 1.5, "the same file: its timing")
        #expect(try offset(c) == 0, "another file keeps its own")
        // Removed on a: b keeps its subtitle.
        try a.database.writer.write { try $0.execute(sql: "DELETE FROM localSubtitle") }
        try a.sync(folder, at: start.addingTimeInterval(30))
        try b.sync(folder, at: start.addingTimeInterval(40))
        #expect(try offset(b) == 1.5)
    }

    /// An address never set on a new device doesn't clear the one set elsewhere; cleared on
    /// purpose later, it is cleared everywhere.
    @Test func kechimochiAddress() throws {
        let collections: [any SyncedCollection] = [TableCollection.kechimochiAddress]
        let a = device("aaaa", "yomu", collections), b = device("bbbb", "yomu", collections)
        try ActivityLog(database: a.database).saveKechimochiURL("http://kechimochi.example:3000")
        try a.sync(folder, at: start)
        try b.database.writer.write { try $0.execute(sql: "INSERT INTO statsState (id) VALUES (1)") }
        try b.sync(folder, at: start.addingTimeInterval(3600))
        #expect(try ActivityLog(database: b.database).kechimochiURL() == "http://kechimochi.example:3000")
        try a.sync(folder, at: start.addingTimeInterval(3700))
        #expect(try ActivityLog(database: a.database).kechimochiURL() == "http://kechimochi.example:3000", "not cleared by b's blank")
        try ActivityLog(database: b.database).saveKechimochiURL(nil)
        try b.sync(folder, at: start.addingTimeInterval(3800))
        try a.sync(folder, at: start.addingTimeInterval(3900))
        #expect(try ActivityLog(database: a.database).kechimochiURL() == nil)
    }

    /// The popup's settings in a shared setup: written by one app on one device, read by
    /// another app on another (they're the setup's, not an app's).
    @Test func popupSettingsAcrossAppsAndDevices() throws {
        let collections: [any SyncedCollection] = [TableCollection.popupSettings]
        let yomuOnA = device("yomu-aaaa", "setup", collections), kikuOnB = device("kiku-bbbb", "setup", collections)
        try yomuOnA.database.writer.write {
            try $0.execute(sql: "INSERT INTO popupSettings (id, showLookupCounts, backgroundOpacityPercent) VALUES (1, 0, 60)")
        }
        try yomuOnA.sync(folder, at: start)
        try kikuOnB.sync(folder, at: start.addingTimeInterval(10))
        let row = try kikuOnB.database.reader.read { try Row.fetchOne($0, sql: "SELECT showLookupCounts, backgroundOpacityPercent FROM popupSettings WHERE id = 1") }
        #expect((row?["showLookupCounts"] as Bool?) == false && (row?["backgroundOpacityPercent"] as Int?) == 60)
    }
}

/// The popup's settings with Hachidori: while it's linked they're Hachidori's to sync, so
/// neither sent nor taken here; unlinked, they sync again.
@Suite struct SetupSyncHachidoriTests {
    let folder = FileManager.default.temporaryDirectory.appending(path: "SetupSyncHachidoriTests-\(UUID().uuidString)")
    let start = Date(timeIntervalSince1970: 1_795_651_200)

    func popup(_ database: AppDatabase, opacity: Int) throws {
        try database.writer.write {
            try $0.execute(sql: "INSERT OR REPLACE INTO popupSettings (id, backgroundOpacityPercent) VALUES (1, ?)", arguments: [opacity])
        }
    }

    func opacity(_ database: AppDatabase) throws -> Int? {
        try database.reader.read { try Int.fetchOne($0, sql: "SELECT backgroundOpacityPercent FROM popupSettings WHERE id = 1") }
    }

    func link(_ database: AppDatabase, _ enabled: Bool) throws {
        try database.writer.write { try HachidoriSettings(enabled: enabled, address: "ws://host.example").save($0) }
    }

    func files() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: folder.appending(path: "popupSettings").path(percentEncoded: false))) ?? []
    }

    @Test func linkedNeitherSendsNorTakesThenUnlinkedSyncs() throws {
        let a = try AppDatabase.inMemory(), b = try AppDatabase.inMemory()
        try popup(a, opacity: 60)
        try link(a, true)
        #expect(try !RecordSync.syncSharedSetup(a, root: folder, app: "yomu", device: "aaaa", now: { start }))
        #expect(files().isEmpty, "linked: nothing sent")

        // Another device, not linked, sends its own; the linked one doesn't take it.
        try popup(b, opacity: 30)
        try RecordSync.syncSharedSetup(b, root: folder, app: "kiku", device: "bbbb", now: { start.addingTimeInterval(10) })
        #expect(files() == ["setup-kiku-bbbb.json"])
        #expect(try !RecordSync.syncSharedSetup(a, root: folder, app: "yomu", device: "aaaa", now: { start.addingTimeInterval(20) }))
        #expect(try opacity(a) == 60, "linked: not taken")

        // Unlinked: a's own settings go out (stamped now, newer than b's) and b takes them.
        try link(a, false)
        try RecordSync.syncSharedSetup(a, root: folder, app: "yomu", device: "aaaa", now: { start.addingTimeInterval(30) })
        #expect(Set(files()) == ["setup-kiku-bbbb.json", "setup-yomu-aaaa.json"])
        #expect(try RecordSync.syncSharedSetup(b, root: folder, app: "kiku", device: "bbbb", now: { start.addingTimeInterval(35) }))
        #expect(try opacity(b) == 60)
        try popup(a, opacity: 75)
        try RecordSync.syncSharedSetup(a, root: folder, app: "yomu", device: "aaaa", now: { start.addingTimeInterval(40) })
        try RecordSync.syncSharedSetup(b, root: folder, app: "kiku", device: "bbbb", now: { start.addingTimeInterval(50) })
        #expect(try opacity(b) == 75, "unlinked: a's change reaches b")
    }
}
