import Core
import Foundation
import GRDB
import Testing

@Suite struct DatabaseTests {
    @Test func migrationsCreateAllTables() throws {
        let db = try AppDatabase.inMemory()
        let tables = try db.reader.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'grdb_%'")
        }
        // FTS5's own shadow tables (transcriptLine_data, audioSentenceSearch_idx, …) aren't ours to list.
        #expect(Set(tables.filter { !$0.hasPrefix("transcriptLine_") && !$0.hasPrefix("audioSentenceSearch_") }) == [
            "serverAccount", "outboxJob", "outboxMedia",
            "kavitaLibrary", "kavitaSeries", "kavitaVolume", "kavitaChapter", "jellyfinItem",
            "kavitaReadingProgress", "mangaReaderSettings", "pageCache",
            "dictionary", "audioSource", "lookupHistory", "dictionarySettings", "dictionarySource",
            "ocrPage",
            "ankiSettings",
            "minedWord",
            "bookReaderSettings",
            "hiddenLibrary",
            "watchProgress", "hiddenJellyfinLibrary",
            "transcript", "transcriptLine",
            "download", "downloadSettings",
            "mediaSegment", "playerSettings",
            "localSubtitle",
            "autoDownloadSetting",
            "activitySession", "lookupEvent", "statsState",
            "japaneseOnlyJellyfinLibrary", "jellyfinAudioCheck",
            "audioTranscript", "audioSentence", "audioSentenceSearch", "listenSettings", "audiobookshelfCache", "audioMark", "readAlongPair",
            "bookLength", "kechimochiCache",
        ])
    }

    @Test func onDiskDatabaseReopensWithData() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try OutboxStore(database: try AppDatabase.onDisk(directory: dir)).enqueue(Card(expression: "a"), kind: .ankiNote)
        #expect(try OutboxStore(database: try AppDatabase.onDisk(directory: dir)).summary().pending == 1)
    }

    @Test func accountsRoundTrip() throws {
        let store = AccountStore(database: try AppDatabase.inMemory())
        let account = ServerAccount(
            kind: .jellyfin, baseURL: URL(string: "https://media.example.ts.net")!,
            username: "me", userId: "abc", serverName: "Home", serverVersion: "10.11.0",
            lastCheckedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        try store.save(account)
        #expect(try store.account(.jellyfin) == account)
        #expect(try store.account(.kavita) == nil)
        try store.delete(.jellyfin)
        #expect(try store.account(.jellyfin) == nil)
    }

    @Test func libraryCacheCascadesFromLibrary() throws {
        let db = try AppDatabase.inMemory()
        let now = Date()
        try db.writer.write { db in
            try KavitaLibraryRecord(id: 1, name: "Manga", type: 0, raw: nil, fetchedAt: now).insert(db)
            try KavitaSeriesRecord(id: 10, libraryId: 1, name: "鉄の時計", sortName: nil, format: 1, pages: 200,
                                   pagesRead: 0, lastReadAt: nil, raw: nil, fetchedAt: now).insert(db)
            try KavitaVolumeRecord(id: 100, seriesId: 10, name: "1", number: 1, pages: 200, pagesRead: 0,
                                   raw: nil, fetchedAt: now).insert(db)
            try KavitaChapterRecord(id: 1000, volumeId: 100, seriesId: 10, title: nil, number: "1", sortOrder: 1,
                                    pages: 200, pagesRead: 0, isSpecial: false, raw: nil, fetchedAt: now).insert(db)
            _ = try KavitaLibraryRecord.deleteOne(db, key: 1)
        }
        #expect(try db.reader.read { try KavitaChapterRecord.fetchCount($0) } == 0)
    }
}

@Suite struct ServerURLTests {
    @Test(arguments: [
        ("https://kavita.example.ts.net/", "https://kavita.example.ts.net"),
        ("  http://192.168.1.5:5000 ", "http://192.168.1.5:5000"),
        ("https://home.example.com/jellyfin//", "https://home.example.com/jellyfin"),
    ])
    func parsesAndNormalizes(input: String, expected: String) throws {
        #expect(try ServerURL.parse(input).absoluteString == expected)
    }

    @Test(arguments: ["", "kavita.local", "ftp://host", "https://", "https://host?x=1"])
    func rejectsInvalid(input: String) {
        #expect(throws: ConnectionError.invalidURL) { try ServerURL.parse(input) }
    }
}

@Suite struct SecretStoreTests {
    @Test func inMemoryStoreSetsAndClears() throws {
        let store = InMemorySecretStore()
        try store.setSecret("k", for: .kavitaAuthKey)
        #expect(try store.secret(for: .kavitaAuthKey) == "k")
        try store.setSecret("", for: .kavitaAuthKey)
        #expect(try store.secret(for: .kavitaAuthKey) == nil)
    }
}

@Suite struct CancellationTests {
    @Test func cancelledRequestsAreRecognised() {
        #expect(CancellationError().isCancellation)
        #expect(ConnectionError.cancelled.isCancellation)
        #expect(ConnectionError(URLError(.cancelled)).isCancellation)
        #expect(URLError(.cancelled).isCancellation)
        #expect(!ConnectionError.timeout.isCancellation)
        #expect(!URLError(.notConnectedToInternet).isCancellation)
    }
}
