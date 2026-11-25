import Foundation
import GRDB

/// Owns the app's SQLite database: server accounts, the outbox and the library cache.
public final class AppDatabase: Sendable {
    public let writer: any DatabaseWriter
    public var reader: any DatabaseReader { writer }

    public init(_ writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    /// The on-disk database in Application Support. WAL mode via `DatabasePool`.
    /// `shared`: the file is in the App Group, used by several processes; it releases its
    /// locks when the app is suspended (`Database.suspendNotification`), or iOS kills the app.
    public static func onDisk(directory: URL, shared: Bool = false) throws -> AppDatabase {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "app.sqlite")
        var configuration = configuration
        configuration.observesSuspensionNotifications = shared
        return try AppDatabase(DatabasePool(path: url.path, configuration: configuration))
    }

    /// Streams a value now and after every change to the tables it reads.
    /// Exposed as a standard stream so callers don't depend on GRDB.
    public func values<Value: Sendable>(
        _ fetch: @escaping @Sendable (Database) throws -> Value
    ) -> AsyncThrowingStream<Value, any Error> {
        let values = ValueObservation.tracking(fetch).values(in: reader)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await value in values { continuation.yield(value) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Yields after every committed change (in this process) to any of `tables`.
    public func changes(to tables: [String]) -> AsyncStream<Void> {
        let observation = DatabaseRegionObservation(tracking: tables.map { Table($0) })
        return AsyncStream { continuation in
            let cancellable = observation.start(in: writer, onError: { _ in continuation.finish() }, onChange: { _ in continuation.yield() })
            continuation.onTermination = { _ in cancellable.cancel() }
        }
    }

    public static func inMemory() throws -> AppDatabase {
        try AppDatabase(DatabaseQueue(configuration: configuration))
    }

    private static var configuration: Configuration {
        var config = Configuration()
        config.foreignKeysEnabled = true
        return config
    }

    // The outbox holds unsent cards, so the schema is never erased on change:
    // every change is a new migration.
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_accounts") { db in
            try db.create(table: "serverAccount") { t in
                t.primaryKey("kind", .text)
                t.column("baseURL", .text).notNull()
                t.column("username", .text)
                t.column("userId", .text)
                t.column("serverName", .text)
                t.column("serverVersion", .text)
                t.column("lastCheckedAt", .datetime)
            }
        }

        migrator.registerMigration("v1_outbox") { db in
            try db.create(table: "outboxJob") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("kind", .text).notNull()
                t.column("coalesceKey", .text)
                t.column("payload", .blob).notNull()
                t.column("state", .text).notNull()
                t.column("attempts", .integer).notNull().defaults(to: 0)
                t.column("lastError", .text)
                t.column("nextAttemptAt", .datetime).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(index: "outboxJob_due", on: "outboxJob", columns: ["state", "nextAttemptAt"])
            try db.execute(sql: """
                CREATE UNIQUE INDEX outboxJob_pendingCoalesceKey ON outboxJob(coalesceKey)
                WHERE coalesceKey IS NOT NULL AND state = 'pending'
                """)

            try db.create(table: "outboxMedia") { t in
                t.autoIncrementedPrimaryKey("id")
                t.belongsTo("job", inTable: "outboxJob", onDelete: .cascade).notNull()
                t.column("field", .text).notNull()
                t.column("filename", .text).notNull()
            }
        }

        migrator.registerMigration("v1_libraryCache") { db in
            try db.create(table: "kavitaLibrary") { t in
                t.primaryKey("id", .integer)
                t.column("name", .text).notNull()
                t.column("type", .integer)
                t.column("raw", .blob)
                t.column("fetchedAt", .datetime).notNull()
            }
            try db.create(table: "kavitaSeries") { t in
                t.primaryKey("id", .integer)
                t.belongsTo("library", inTable: "kavitaLibrary", onDelete: .cascade).notNull()
                t.column("name", .text).notNull()
                t.column("sortName", .text)
                t.column("format", .integer)
                t.column("pages", .integer)
                t.column("pagesRead", .integer)
                t.column("lastReadAt", .datetime)
                t.column("raw", .blob)
                t.column("fetchedAt", .datetime).notNull()
            }
            try db.create(table: "kavitaVolume") { t in
                t.primaryKey("id", .integer)
                t.belongsTo("series", inTable: "kavitaSeries", onDelete: .cascade).notNull()
                t.column("name", .text)
                t.column("number", .double)
                t.column("pages", .integer)
                t.column("pagesRead", .integer)
                t.column("raw", .blob)
                t.column("fetchedAt", .datetime).notNull()
            }
            try db.create(table: "kavitaChapter") { t in
                t.primaryKey("id", .integer)
                t.belongsTo("volume", inTable: "kavitaVolume", onDelete: .cascade).notNull()
                t.column("seriesId", .integer).notNull().indexed()
                t.column("title", .text)
                t.column("number", .text)
                t.column("sortOrder", .double)
                t.column("pages", .integer)
                t.column("pagesRead", .integer)
                t.column("isSpecial", .boolean).notNull().defaults(to: false)
                t.column("raw", .blob)
                t.column("fetchedAt", .datetime).notNull()
            }
            try db.create(table: "jellyfinItem") { t in
                t.primaryKey("id", .text)
                t.column("parentId", .text).indexed()
                t.column("seriesId", .text).indexed()
                t.column("type", .text).notNull()
                t.column("name", .text).notNull()
                t.column("sortName", .text)
                t.column("indexNumber", .integer)
                t.column("parentIndexNumber", .integer)
                t.column("runTimeTicks", .integer)
                t.column("playbackPositionTicks", .integer)
                t.column("played", .boolean).notNull().defaults(to: false)
                t.column("raw", .blob)
                t.column("fetchedAt", .datetime).notNull()
            }
        }

        migrator.registerMigration("v2_reader") { db in
            try db.create(table: "kavitaReadingProgress") { t in
                t.primaryKey("chapterId", .integer)
                t.column("seriesId", .integer).notNull().indexed()
                t.column("volumeId", .integer).notNull()
                t.column("libraryId", .integer).notNull()
                t.column("page", .integer).notNull()
                t.column("pages", .integer).notNull()
                t.column("updatedAt", .datetime).notNull().indexed()
            }
            try db.create(table: "mangaReaderSettings") { t in
                // 'global' or 'kavita.series.<id>'
                t.primaryKey("scope", .text)
                t.column("settings", .blob).notNull()
            }
            try db.create(table: "pageCache") { t in
                t.primaryKey("key", .text)
                t.column("chapterId", .integer).notNull().indexed()
                t.column("page", .integer).notNull()
                t.column("filename", .text).notNull()
                t.column("bytes", .integer).notNull()
                t.column("lastAccessAt", .datetime).notNull().indexed()
                t.column("pinned", .boolean).notNull().defaults(to: false)
            }
        }

        migrator.registerMigration("v3_dictionary") { db in
            // Installed Yomitan dictionaries. Their content lives in hoshidicts folders
            // under Application Support/Dictionaries/<id>; only metadata is stored here.
            try db.create(table: "dictionary") { t in
                t.primaryKey("id", .text)
                t.column("title", .text).notNull().unique()
                t.column("revision", .text)
                t.column("attribution", .text)
                t.column("hasTerms", .boolean).notNull()
                t.column("hasFrequencies", .boolean).notNull()
                t.column("hasPitches", .boolean).notNull()
                t.column("hasKanji", .boolean).notNull()
                t.column("termCount", .integer).notNull()
                t.column("metaCount", .integer).notNull()
                t.column("kanjiCount", .integer).notNull()
                t.column("mediaCount", .integer).notNull()
                t.column("bytes", .integer).notNull()
                t.column("enabled", .boolean).notNull().defaults(to: true)
                t.column("sortOrder", .integer).notNull()
                t.column("importedAt", .datetime).notNull()
            }
            try db.create(table: "audioSource") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("kind", .text).notNull()
                t.column("name", .text).notNull()
                t.column("template", .text).notNull()
                t.column("enabled", .boolean).notNull().defaults(to: true)
                t.column("sortOrder", .integer).notNull()
            }
            try db.create(table: "lookupHistory") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("query", .text).notNull()
                t.column("expression", .text).notNull()
                t.column("reading", .text).notNull()
                t.column("createdAt", .datetime).notNull().indexed()
            }
            try db.create(table: "dictionarySettings") { t in
                t.primaryKey("id", .integer)
                t.column("frequencySortTitle", .text)
            }
        }

        migrator.registerMigration("v4_ocr") { db in
            // OCR results per page, so each page is processed once per model version.
            try db.create(table: "ocrPage") { t in
                t.column("chapterId", .integer).notNull()
                t.column("page", .integer).notNull()
                t.column("modelVersion", .text).notNull()
                t.column("result", .blob).notNull()
                t.column("createdAt", .datetime).notNull()
                t.primaryKey(["chapterId", "page", "modelVersion"])
            }
        }

        migrator.registerMigration("v5_anki") { db in
            // Mining settings (one row) and the words already in Anki or queued, for duplicate marks.
            try db.create(table: "ankiSettings") { t in
                t.primaryKey("id", .integer)
                t.column("settings", .blob).notNull()
            }
            try db.create(table: "minedWord") { t in
                t.column("expression", .text).notNull()
                t.column("reading", .text).notNull()
                t.column("source", .text).notNull()
                t.column("jobId", .integer)
                t.column("updatedAt", .datetime).notNull()
                t.primaryKey(["expression", "reading"])
            }
        }

        migrator.registerMigration("v6_books") { db in
            try db.alter(table: "kavitaReadingProgress") { t in
                t.add(column: "scrollId", .text)
            }
            try db.create(table: "bookReaderSettings") { t in
                // 'global' or 'kavita.series.<id>'
                t.primaryKey("scope", .text)
                t.column("settings", .blob).notNull()
            }
            // Libraries the user turned off in Settings.
            try db.create(table: "hiddenLibrary") { t in
                t.primaryKey("libraryId", .integer)
            }
        }

        migrator.registerMigration("v7_player") { db in
            // The last position played on this device, so a resume works before Jellyfin hears of it.
            try db.create(table: "watchProgress") { t in
                t.primaryKey("itemId", .text)
                t.column("seriesId", .text)
                t.column("position", .double).notNull()
                t.column("duration", .double).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            // Jellyfin libraries the user turned off in Settings (string ids, unlike Kavita's).
            try db.create(table: "hiddenJellyfinLibrary") { t in
                t.primaryKey("libraryId", .text)
            }
        }

        migrator.registerMigration("v8_lines") { db in
            // Saved Japanese subtitles of watched episodes (the Lines tab).
            try db.create(table: "transcript") { t in
                t.primaryKey("itemId", .text)
                t.column("seriesId", .text)
                t.column("seriesName", .text)
                t.column("title", .text).notNull()
                t.column("season", .integer)
                t.column("episode", .integer)
                t.column("mediaSourceId", .text).notNull()
                t.column("streamIndex", .integer).notNull()
                // The Japanese audio stream, as FFmpeg numbers it (for clips); nil = the file's default.
                t.column("audioIndex", .integer)
                t.column("runtime", .double)
                t.column("lastPlayedAt", .datetime)
                t.column("savedAt", .datetime).notNull()
            }
            // Trigram tokens: substring search in Japanese without word segmentation.
            try db.execute(sql: """
                CREATE VIRTUAL TABLE transcriptLine USING fts5(
                    text, itemId UNINDEXED, cue UNINDEXED, start UNINDEXED, "end" UNINDEXED, tokenize = 'trigram')
                """)
        }

        migrator.registerMigration("v9_downloads") { db in
            // Content the user chose to keep on the device (volumes, episodes).
            try db.create(table: "download") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("kind", .text).notNull()
                t.column("itemKey", .text).notNull()
                t.column("seriesKey", .text)
                t.column("seriesTitle", .text).notNull()
                t.column("title", .text).notNull()
                t.column("detail", .text)
                t.column("state", .text).notNull()
                t.column("bytesDone", .integer).notNull().defaults(to: 0)
                t.column("bytesTotal", .integer)
                t.column("error", .text)
                t.column("file", .text)
                t.column("extra", .blob)
                t.column("createdAt", .datetime).notNull()
                t.column("completedAt", .datetime)
                t.uniqueKey(["kind", "itemKey"])
            }
            try db.create(table: "downloadSettings") { t in
                t.primaryKey("id", .integer)
                t.column("allowsCellular", .boolean).notNull().defaults(to: false)
                t.column("readsDownloadedPages", .boolean).notNull().defaults(to: true)
            }
        }

        migrator.registerMigration("v10_segments") { db in
            // Intros, credits etc. per Jellyfin item, kept so downloaded episodes skip offline too.
            try db.create(table: "mediaSegment") { t in
                t.column("itemId", .text).notNull().indexed()
                t.column("kind", .text).notNull()
                t.column("start", .double).notNull()
                t.column("end", .double).notNull()
            }
            try db.create(table: "playerSettings") { t in
                t.primaryKey("id", .integer)
                t.column("autoSkipsIntros", .boolean).notNull().defaults(to: false)
            }
        }

        migrator.registerMigration("v11_local_subtitles") { db in
            // Subtitles found outside Jellyfin (Jimaku) for an item, as downloaded, with the
            // user's timing offset; uploaded to Jellyfin through the outbox.
            try db.create(table: "localSubtitle") { t in
                t.primaryKey("itemId", .text)
                t.column("source", .text).notNull()
                t.column("fileName", .text).notNull()
                t.column("format", .text).notNull()
                t.column("data", .blob).notNull()
                t.column("offset", .double).notNull().defaults(to: 0)
                t.column("savedAt", .datetime).notNull()
                t.column("uploadedAt", .datetime)
            }
        }

        migrator.registerMigration("v12_subtitle_sync") { db in
            // The file as downloaded once a sync rewrote `data` (Reset goes back to it), when
            // the user last changed the subtitle, and when they last asked to save it to Jellyfin.
            try db.alter(table: "localSubtitle") { t in
                t.add(column: "originalData", .blob)
                t.add(column: "editedAt", .datetime)
                t.add(column: "queuedAt", .datetime)
            }
        }

        migrator.registerMigration("v13_auto_downloads") { db in
            // Reader: per Kavita library, how many volumes to keep downloaded past the one
            // being read, and whether finished volumes are removed.
            try db.create(table: "autoDownloadSetting") { t in
                t.primaryKey("libraryId", .integer)
                t.column("ahead", .integer).notNull().defaults(to: 0)
                t.column("removesFinished", .boolean).notNull().defaults(to: false)
            }
        }

        migrator.registerMigration("v14_merge_song_copies") { db in
            // Transcripts saved before song lines drawn as many copies were merged.
            let items = try String.fetchAll(db, sql: "SELECT itemId FROM transcript")
            let insert = try db.makeStatement(sql: #"INSERT INTO transcriptLine (text, itemId, cue, start, "end") VALUES (?, ?, ?, ?, ?)"#)
            for itemId in items {
                let rows = try Row.fetchAll(db, sql: #"SELECT text, start, "end" FROM transcriptLine WHERE itemId = ? ORDER BY cue"#,
                                            arguments: [itemId])
                let lines = rows.map { (start: $0["start"] as Double, end: $0["end"] as Double, text: $0["text"] as String) }
                let merged = TranscriptLines.mergingCopies(lines)
                guard merged.count < lines.count else { continue }
                try db.execute(sql: "DELETE FROM transcriptLine WHERE itemId = ?", arguments: [itemId])
                for (cue, line) in merged.enumerated() {
                    try insert.execute(arguments: [line.text, itemId, cue, line.start, line.end])
                }
            }
        }

        migrator.registerMigration("v15_word_marks") { db in
            // Mined words whose card has an interval of 21 days or more (word marks: known).
            try db.alter(table: "minedWord") { t in
                t.add(column: "known", .boolean).notNull().defaults(to: false)
            }
        }

        migrator.registerMigration("v16_stats") { db in
            // The Stats tab: reading and watching sessions, lookups, and saved state.
            try db.create(table: "activitySession") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("kind", .text).notNull()
                t.column("seriesKey", .text).notNull()
                t.column("seriesTitle", .text).notNull()
                t.column("itemKey", .text).notNull()
                t.column("start", .datetime).notNull()
                t.column("end", .datetime).notNull()
                t.column("characters", .integer).notNull().defaults(to: 0)
                t.column("pages", .integer).notNull().defaults(to: 0)
                t.column("seconds", .double).notNull().defaults(to: 0)
            }
            try db.create(index: "activitySession_item", on: "activitySession", columns: ["kind", "itemKey", "end"])
            try db.create(table: "lookupEvent") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("createdAt", .datetime).notNull().indexed()
            }
            try db.create(table: "statsState") { t in
                t.primaryKey("id", .integer)
                t.column("ankiNoteIds", .blob)
                t.column("kechimochiURL", .text)
            }
        }

        migrator.registerMigration("v17_server_subtitle") { db in
            // Retimed copies of Jellyfin's own subtitle tracks: which track, and its file if separate.
            try db.alter(table: "localSubtitle") { t in
                t.add(column: "serverIndex", .integer)
                t.add(column: "serverPath", .text)
            }
        }

        migrator.registerMigration("v18_japanese_audio") { db in
            // Miru: libraries showing only items with a Japanese audio track, each series'
            // answer (from its first episode), and the card picture style.
            try db.create(table: "japaneseOnlyJellyfinLibrary") { t in
                t.primaryKey("libraryId", .text)
            }
            try db.create(table: "jellyfinAudioCheck") { t in
                t.primaryKey("itemId", .text)
                t.column("hasJapanese", .boolean).notNull()
                t.column("checkedAt", .datetime).notNull()
            }
            try db.alter(table: "playerSettings") { t in
                t.add(column: "cardPicture", .text).notNull().defaults(to: "screenshot")
            }
        }

        migrator.registerMigration("v19_kiku") { db in
            // Kiku: Kaku transcripts saved on the device (episodes played or downloaded), so the
            // player and Marks search work offline. Sentences are searched like Miru's lines.
            try db.create(table: "audioTranscript") { t in
                t.primaryKey("key", .text)
                t.column("itemId", .text).notNull()
                t.column("episodeId", .text).notNull()
                t.column("showTitle", .text).notNull()
                t.column("episodeTitle", .text).notNull()
                t.column("fingerprint", .text)
                t.column("duration", .double)
                t.column("savedAt", .datetime).notNull()
                t.column("lastPlayedAt", .datetime)
            }
            try db.create(table: "audioSentence") { t in
                t.column("key", .text).notNull().indexed()
                t.column("position", .integer).notNull()
                t.column("start", .double).notNull()
                t.column("end", .double).notNull()
                t.column("text", .text).notNull()
                // [{text, start, end}], for word-level timing.
                t.column("words", .blob)
                t.primaryKey(["key", "position"])
            }
            // Kiku's playback settings: Lock Screen and AirPods skips, and the starting speed.
            try db.create(table: "listenSettings") { t in
                t.primaryKey("id", .integer).check { $0 == 1 }
                t.column("skipBackward", .double).notNull().defaults(to: 15)
                t.column("skipForward", .double).notNull().defaults(to: 30)
                t.column("speed", .double).notNull().defaults(to: 1)
            }
            try db.execute(sql: """
                CREATE VIRTUAL TABLE audioSentenceSearch USING fts5(
                    text, key UNINDEXED, position UNINDEXED, tokenize = 'trigram')
                """)
        }

        migrator.registerMigration("v20_kiku_cache") { db in
            // Kiku: the last library answers from Audiobookshelf, for browsing offline.
            try db.create(table: "audiobookshelfCache") { t in
                t.primaryKey("key", .text)
                t.column("raw", .blob).notNull()
                t.column("fetchedAt", .datetime).notNull()
            }
        }

        migrator.registerMigration("v21_kiku_marks") { db in
            // Kiku: marks made while listening ("mark now, mine later"), kept on the device.
            try db.create(table: "audioMark") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("itemId", .text).notNull()
                t.column("episodeId", .text).notNull()
                t.column("showTitle", .text).notNull()
                t.column("episodeTitle", .text).notNull()
                t.column("time", .double).notNull()
                t.column("createdAt", .datetime).notNull().indexed()
                t.column("source", .text).notNull()
                t.column("minedAt", .datetime)
                t.column("minedWord", .text)
                t.column("minedJobId", .integer)
            }
        }

        migrator.registerMigration("v22_kiku_books") { db in
            // Kiku: which Audiobookshelf libraries it hides (a JSON array of ids).
            try db.alter(table: "listenSettings") { t in
                t.add(column: "hiddenLibraries", .text).notNull().defaults(to: "[]")
            }
        }

        migrator.registerMigration("v23_read_along") { db in
            // Yomu: an EPUB volume paired with an audiobook, and its alignment once prepared.
            try db.create(table: "readAlongPair") { t in
                t.primaryKey("chapterId", .integer)
                t.column("itemId", .text).notNull()
                t.column("bookTitle", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("alignedAt", .datetime)
                t.column("transcriptFingerprint", .text)
                t.column("alignmentVersion", .integer)
                t.column("cues", .blob)
                t.column("matchedSentences", .integer)
                t.column("totalSentences", .integer)
            }
        }

        migrator.registerMigration("v24_read_along_off") { db in
            // Yomu: a paired volume can be read without the audio (remembered per volume).
            try db.alter(table: "readAlongPair") { t in
                t.add(column: "readsAlong", .boolean).notNull().defaults(to: true)
            }
        }

        migrator.registerMigration("v25_reading_characters") { db in
            // Yomu: characters read in a book, as the reader counts them.
            try db.alter(table: "kavitaReadingProgress") { t in
                t.add(column: "characters", .integer)
            }
        }

        migrator.registerMigration("v26_counted_letters") { db in
            // Yomu counts letters only now (as Hoshi Reader does): places saved in the old count
            // open from their XPath once, and save the new count after.
            try db.execute(sql: "UPDATE kavitaReadingProgress SET characters = NULL")
        }

        migrator.registerMigration("v27_book_length") { db in
            // Yomu: each EPUB volume's characters per section, counted from the book or Kavita's text.
            try db.create(table: "bookLength") { t in
                t.primaryKey("chapterId", .integer)
                t.column("seriesId", .integer).notNull().indexed()
                t.column("sections", .text).notNull()
                t.column("total", .integer).notNull()
                t.column("kavitaWordCount", .integer)
                t.column("kavitaPages", .integer).notNull()
                t.column("countedAt", .datetime).notNull()
            }
        }

        migrator.registerMigration("v28_merge_build_ups") { db in
            // Miru's Lines: karaoke build-ups saved before they were merged (「恋」 then 「恋をしたから」).
            let items = try String.fetchAll(db, sql: "SELECT itemId FROM transcript")
            let insert = try db.makeStatement(sql: #"INSERT INTO transcriptLine (text, itemId, cue, start, "end") VALUES (?, ?, ?, ?, ?)"#)
            for itemId in items {
                let rows = try Row.fetchAll(db, sql: #"SELECT text, start, "end" FROM transcriptLine WHERE itemId = ? ORDER BY cue"#,
                                            arguments: [itemId])
                let lines = rows.map { (start: $0["start"] as Double, end: $0["end"] as Double, text: $0["text"] as String) }
                let merged = TranscriptLines.mergingBuildUps(lines)
                guard merged.count < lines.count else { continue }
                try db.execute(sql: "DELETE FROM transcriptLine WHERE itemId = ?", arguments: [itemId])
                for (cue, line) in merged.enumerated() {
                    try insert.execute(arguments: [line.text, itemId, cue, line.start, line.end])
                }
            }
        }

        migrator.registerMigration("v29_kechimochi_cache") { db in
            // Stats ▸ All immersion: kechimochi's last answers (the snapshot, each year's heatmap).
            try db.create(table: "kechimochiCache") { t in
                t.primaryKey("key", .text)
                t.column("data", .blob).notNull()
                t.column("fetchedAt", .datetime).notNull()
            }
        }

        migrator.registerMigration("v30_transcript_toggle") { db in
            // Kiku: the player's transcript on or off (its speech-bubble button), for every episode.
            try db.alter(table: "listenSettings") { t in
                t.add(column: "showsTranscript", .boolean).notNull().defaults(to: true)
            }
        }

        migrator.registerMigration("v31_dictionary_source") { db in
            // Recommended dictionaries that keep themselves up to date.
            // An update keeps the dictionary's id and installs into a new folder beside the old one.
            try db.alter(table: "dictionary") { t in
                t.add(column: "folder", .text)
            }
            // Where each dictionary came from: the recommended set's entry, and the update
            // address from its own index.json.
            try db.create(table: "dictionarySource") { t in
                t.primaryKey("dictionaryId", .text).references("dictionary", onDelete: .cascade)
                t.column("catalogId", .text)
                t.column("indexUrl", .text)
                t.column("downloadUrl", .text)
                t.column("isUpdatable", .boolean).notNull().defaults(to: false)
                t.column("checkedAt", .datetime)
                // The newest revision the index named that a download didn't bring (a stale
                // mirror): not tried again until the index names another one.
                t.column("undeliveredRevision", .text)
            }
            try db.alter(table: "dictionarySettings") { t in
                t.add(column: "autoUpdate", .boolean).notNull().defaults(to: true)
                t.add(column: "lastUpdateCheck", .datetime)
                // Recommended dictionaries the user deleted (catalog ids, JSON): never reinstalled.
                t.add(column: "removedRecommended", .text).notNull().defaults(to: "[]")
            }
        }

        migrator.registerMigration("v32_lookup_counts") { db in
            // How often each headword was looked up, in every app (part of the shared setup),
            // counted like Hachidori's lookup statistics (LookupCounts.swift).
            try db.create(table: "lookupCount") { t in
                t.column("term", .text).notNull()
                t.column("reading", .text).notNull()
                t.column("lookupCount", .integer).notNull()
                t.column("firstLookedUpAt", .datetime).notNull()
                t.column("lastLookedUpAt", .datetime).notNull()
                t.primaryKey(["term", "reading"])
            }
            // The popup's own settings (Settings ▸ Popup), shared like the dictionaries.
            try db.create(table: "popupSettings") { t in
                t.primaryKey("id", .integer)
                t.column("showLookupCounts", .boolean).notNull().defaults(to: true)
            }
        }

        migrator.registerMigration("v33_compact_summary") { db in
            // Hachidori's compact definition summary (Settings ▸ Popup ▸ First Meaning): off by
            // default, as in Hachidori; 3 snippets; nil dictionary = automatic.
            try db.alter(table: "popupSettings") { t in
                t.add(column: "showCompactDefinitionSummary", .boolean).notNull().defaults(to: false)
                t.add(column: "compactDefinitionSummaryCount", .integer).notNull().defaults(to: 3)
                t.add(column: "compactDefinitionSummaryDictionary", .text)
            }
        }

        migrator.registerMigration("v34_popup_opacity") { db in
            // Hachidori's Background opacity (Settings ▸ Popup): 0–100 %, 85 by default; text stays opaque.
            try db.alter(table: "popupSettings") { t in
                t.add(column: "backgroundOpacityPercent", .integer).notNull().defaults(to: 85)
            }
        }

        migrator.registerMigration("v35_hachidori") { db in
            // Settings ▸ Hachidori: the host the Mac apps look words up on (part of the shared
            // setup). The address is the user's own; there's no default.
            try db.create(table: "hachidoriSettings") { t in
                t.primaryKey("id", .integer)
                t.column("enabled", .boolean).notNull().defaults(to: false)
                t.column("address", .text).notNull().defaults(to: "")
            }
        }

        migrator.registerMigration("v36_popup_blur") { db in
            // Settings ▸ Popup ▸ Background Blur: 0–100 %, 50 by default (the blur the apps had).
            try db.alter(table: "popupSettings") { t in
                t.add(column: "backgroundBlurPercent", .integer).notNull().defaults(to: 50)
            }
        }

        migrator.registerMigration("v37_no_popup_blur") { db in
            // The blur is always full now, like Hachidori's (fading a material cross-fades a
            // sharp and a blurred copy of what's behind): the setting goes.
            try db.alter(table: "popupSettings") { t in
                t.drop(column: "backgroundBlurPercent")
            }
        }

        migrator.registerMigration("v38_pinned") { db in
            // Series, shows and books pinned to the Mac's sidebar (each app its own).
            try db.create(table: "pinnedItem") { t in
                t.primaryKey("id", .text)
                t.column("kind", .text).notNull()
                t.column("title", .text).notNull()
                t.column("pinnedAt", .datetime).notNull()
            }
        }

        migrator.registerMigration("v39_word_status") { db in
            // Words marked known or ignored by hand (Hachidori's wordStatusOverrides), in the setup.
            try db.create(table: "wordStatus") { t in
                t.primaryKey("headword", .text)
                t.column("status", .text)
                t.column("updatedAt", .datetime).notNull()
                t.column("pendingHost", .boolean).notNull().defaults(to: false)
            }
        }

        migrator.registerMigration("v40_watch_live_text") { db in
            // Kiku: Live Text on Apple Watch (off until turned on in Settings ▸ Playback).
            try db.alter(table: "listenSettings") { t in
                t.add(column: "watchLiveText", .boolean).notNull().defaults(to: false)
            }
        }

        migrator.registerMigration("v41_audio_auto_downloads") { db in
            // Kiku: download ahead, per podcast library ("library:<id>") or show ("show:<item id>").
            try db.create(table: "audioAutoDownloadSetting") { t in
                t.primaryKey("scope", .text)
                t.column("ahead", .integer).notNull().defaults(to: 0)
                t.column("order", .text).notNull().defaults(to: "newest")
                t.column("isOn", .boolean)
            }
        }

        migrator.registerMigration("v42_download_once_started") { db in
            // Kiku: a library's "Download Once Started" (podcasts and books).
            try db.alter(table: "audioAutoDownloadSetting") { t in
                t.add(column: "onceStarted", .boolean).notNull().defaults(to: false)
            }
        }

        migrator.registerMigration("v43_remove_played_downloads") { db in
            // Kiku: a library's Remove Played Downloads and Keep Downloads You Made by Hand, and
            // the automatic downloads you deleted (never fetched again).
            try db.alter(table: "audioAutoDownloadSetting") { t in
                t.add(column: "removesPlayed", .boolean).notNull().defaults(to: false)
                t.add(column: "keepsManual", .boolean).notNull().defaults(to: true)
            }
            try db.create(table: "audioDownloadDeclined") { t in
                t.primaryKey("key", .text)
                t.column("declinedAt", .datetime).notNull()
            }
        }

        migrator.registerMigration("v44_kiku_watch_items") { db in
            // Kiku: what's sent to Apple Watch (docs/KIKU_PLAN.md milestone 2), each item as
            // KikuWatchLink's WatchItem JSON (Core doesn't know its type).
            try db.create(table: "kikuWatchItem") { t in
                t.primaryKey("key", .text)
                t.column("item", .blob).notNull()
                t.column("addedAt", .datetime).notNull()
            }
        }

        migrator.registerMigration("v45_kiku_watch_listening") { db in
            // Kiku: listening on Apple Watch the phone has applied (milestone 3), by the watch's
            // id: the version applied (its seconds and end), so a stretch sent again adds only
            // what's new and one sent twice nothing.
            try db.create(table: "kikuWatchListening") { t in
                t.primaryKey("id", .text)
                t.column("seconds", .double).notNull()
                t.column("endedAt", .datetime).notNull()
                t.column("appliedAt", .datetime).notNull()
            }
        }

        migrator.registerMigration("v46_kiku_watch_rules") { db in
            // Kiku: automatic rules for Apple Watch (docs/KIKU_PLAN.md milestone 4), one row, and
            // the automatic items removed from the watch (never added again).
            try db.create(table: "kikuWatchRules") { t in
                t.primaryKey("id", .integer)
                t.column("onceStarted", .boolean).notNull().defaults(to: false)
                t.column("ahead", .integer).notNull().defaults(to: 0)
                t.column("removesPlayed", .boolean).notNull().defaults(to: false)
                t.column("keepsManual", .boolean).notNull().defaults(to: true)
                t.column("storageLimit", .integer).notNull().defaults(to: 0)
            }
            try db.create(table: "kikuWatchDeclined") { t in
                t.primaryKey("key", .text)
                t.column("declinedAt", .datetime).notNull()
            }
        }

        migrator.registerMigration("v47_transcript_source") { db in
            // Kiku: what made each saved transcript and when, for the player's Transcript menu (#149).
            try db.alter(table: "audioTranscript") { t in
                t.add(column: "model", .text)
                t.add(column: "kakuVersion", .text)
                t.add(column: "transcribedAt", .datetime)
            }
        }

        migrator.registerMigration("v48_hover_lookup") { db in
            // Settings ▸ Popup ▸ Look Up on Hover (the Mac): the key held while pointing at a word,
            // Shift by default; "always" needs no key, "off" keeps lookups to clicks.
            try db.alter(table: "popupSettings") { t in
                t.add(column: "hoverLookup", .text).notNull().defaults(to: "shift")
            }
        }

        migrator.registerMigration("v49_player_speed_and_line_pause") { db in
            // Miru: the speed chosen in the player is kept, and Pause After Each Line (off by default).
            try db.alter(table: "playerSettings") { t in
                t.add(column: "speed", .double).notNull().defaults(to: 1)
                t.add(column: "pausesAfterLines", .boolean).notNull().defaults(to: false)
            }
        }

        migrator.registerMigration("v50_kiku_plays_next") { db in
            // Kiku: Play the Next Episode (Settings ▸ Playback), on by default.
            try db.alter(table: "listenSettings") { t in
                t.add(column: "playsNextEpisode", .boolean).notNull().defaults(to: true)
            }
        }

        migrator.registerMigration("v51_kiku_listening_extras") { db in
            // Kiku: the transcript's text size, Pause After Each Line, and each show's own speed
            // and seconds to skip at the start and end.
            try db.alter(table: "listenSettings") { t in
                t.add(column: "transcriptScale", .double).notNull().defaults(to: 1)
                t.add(column: "pausesAfterLines", .boolean).notNull().defaults(to: false)
            }
            try db.create(table: "showListenSetting") { t in
                t.primaryKey("itemId", .text)
                t.column("speed", .double)
                t.column("skipStart", .double).notNull().defaults(to: 0)
                t.column("skipEnd", .double).notNull().defaults(to: 0)
            }
        }

        migrator.registerMigration("v52_miru_subtitle_look") { db in
            // Miru: the subtitles' size and height, blurring them until tapped, and pausing while
            // the pointer is on them (the Mac).
            try db.alter(table: "playerSettings") { t in
                t.add(column: "subtitleScale", .double).notNull().defaults(to: 1)
                t.add(column: "subtitleLift", .double).notNull().defaults(to: 0)
                t.add(column: "concealsSubtitles", .boolean).notNull().defaults(to: false)
                t.add(column: "pausesOnHover", .boolean).notNull().defaults(to: false)
            }
        }

        migrator.registerMigration("v53_stats_sync") { db in
            // Stats across devices (StatsSync): rows that came from another device carry its
            // name; this install's own name; and what's been sent and read so far.
            try db.alter(table: "activitySession") { t in
                t.add(column: "device", .text)
            }
            try db.alter(table: "lookupEvent") { t in
                t.add(column: "device", .text)
            }
            try db.alter(table: "statsState") { t in
                t.add(column: "deviceId", .text)
                t.add(column: "deviceHardware", .text)
            }
            try db.create(table: "statsSyncFile") { t in
                t.primaryKey("name", .text)
                t.column("token", .text).notNull()
            }
        }

        migrator.registerMigration("v54_miru_stream_quality") { db in
            // Miru: the streaming quality (0 = the original file; else Jellyfin transcodes down to it).
            try db.alter(table: "playerSettings") { t in
                t.add(column: "maxStreamBitrate", .integer).notNull().defaults(to: 0)
            }
        }

        migrator.registerMigration("v55_popup_close_on_pointer_exit") { db in
            // Settings ▸ Popup ▸ Close When the Pointer Leaves (the Mac), off by default.
            try db.alter(table: "popupSettings") { t in
                t.add(column: "closeOnPointerExit", .boolean).notNull().defaults(to: false)
            }
        }

        migrator.registerMigration("v56_reader_marks") { db in
            // Yomu's bookmarks and highlights, kept on Kavita: the device's copy and what's unsent.
            try db.create(table: "readerMark") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("account", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("serverId", .integer)
                t.column("libraryId", .integer).notNull()
                t.column("seriesId", .integer).notNull()
                t.column("volumeId", .integer).notNull()
                t.column("chapterId", .integer).notNull()
                t.column("page", .integer).notNull()
                t.column("xpath", .text)
                t.column("endXPath", .text)
                t.column("text", .text)
                t.column("title", .text)
                t.column("note", .text)
                t.column("slot", .integer).notNull().defaults(to: 0)
                t.column("state", .text).notNull()
                t.column("revision", .integer).notNull().defaults(to: 0)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(index: "readerMark_series", on: "readerMark", columns: ["account", "seriesId"])
            // What a Kavita server turned out not to offer (annotations before 0.8.8, page
            // bookmarks without the Bookmark role).
            try db.create(table: "kavitaFeature") { t in
                t.column("account", .text).notNull()
                t.column("feature", .text).notNull()
                t.column("available", .boolean).notNull()
                t.column("checkedAt", .datetime).notNull()
                t.primaryKey(["account", "feature"])
            }
        }

        migrator.registerMigration("v57_want_to_read") { db in
            // Kavita's Want to Read per account: its list, and the toggles not sent yet.
            try db.create(table: "wantToRead") { t in
                t.column("account", .text).notNull()
                t.column("seriesId", .integer).notNull()
                t.column("state", .text).notNull()
                t.column("position", .integer).notNull().defaults(to: 0)
                t.column("revision", .integer).notNull().defaults(to: 0)
                t.column("updatedAt", .datetime).notNull()
                t.primaryKey(["account", "seriesId"])
            }
        }

        migrator.registerMigration("v58_collections") { db in
            // Kavita's collections per account, and their series: Kavita's lists and the
            // changes not sent yet.
            try db.create(table: "kavitaCollection") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("account", .text).notNull()
                t.column("serverId", .integer)
                t.column("title", .text).notNull()
                t.column("isOwn", .boolean).notNull()
                t.column("owner", .text)
                t.column("promoted", .boolean).notNull()
                t.column("source", .integer).notNull()
                t.column("itemCount", .integer).notNull()
                t.column("position", .integer).notNull()
                t.column("state", .text).notNull()
                t.column("confirmed", .boolean).notNull()
                t.column("createAttempts", .integer).notNull()
                t.column("seriesReadAt", .datetime)
                t.column("revision", .integer).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(index: "kavitaCollection_account", on: "kavitaCollection", columns: ["account"])
            try db.create(table: "kavitaCollectionSeries") { t in
                t.column("collectionId", .integer).notNull().references("kavitaCollection", onDelete: .cascade)
                t.column("seriesId", .integer).notNull()
                t.column("state", .text).notNull()
                t.column("inKavita", .boolean).notNull()
                t.column("revision", .integer).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.primaryKey(["collectionId", "seriesId"])
            }
        }

        migrator.registerMigration("v59_reading_lists") { db in
            // Kavita's reading lists per account, their items, and moves not sent yet.
            try db.create(table: "kavitaReadingList") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("account", .text).notNull()
                t.column("serverId", .integer)
                t.column("title", .text).notNull()
                t.column("isOwn", .boolean).notNull()
                t.column("owner", .text)
                t.column("promoted", .boolean).notNull()
                t.column("isSynced", .boolean).notNull()
                t.column("kavitaItemCount", .integer)
                t.column("position", .integer).notNull()
                t.column("state", .text).notNull()
                t.column("createAttempts", .integer).notNull()
                t.column("itemsReadAt", .datetime)
                t.column("itemsStale", .boolean).notNull()
                t.column("revision", .integer).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(index: "kavitaReadingList_account", on: "kavitaReadingList", columns: ["account"])
            try db.create(table: "kavitaReadingListItem") { t in
                t.column("listId", .integer).notNull().references("kavitaReadingList", onDelete: .cascade)
                t.column("chapterId", .integer).notNull()
                t.column("serverItemId", .integer)
                t.column("seriesId", .integer).notNull()
                t.column("volumeId", .integer).notNull()
                t.column("libraryId", .integer).notNull()
                t.column("format", .integer).notNull()
                t.column("seriesName", .text).notNull()
                t.column("title", .text).notNull()
                t.column("kavitaOrder", .integer).notNull()
                t.column("state", .text).notNull()
                t.column("inKavita", .boolean).notNull()
                t.column("revision", .integer).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.primaryKey(["listId", "chapterId"])
            }
            try db.create(table: "kavitaReadingListMove") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("listId", .integer).notNull().references("kavitaReadingList", onDelete: .cascade)
                t.column("chapterId", .integer).notNull()
                t.column("anchors", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }
        }

        migrator.registerMigration("v60_outbox_waiting") { db in
            // A job waiting for another one (`OutboxWait`), told apart from one that failed.
            try db.alter(table: "outboxJob") { t in
                t.add(column: "waitingFor", .text)
            }
        }

        migrator.registerMigration("v61_reading_list_reading") { db in
            // Kavita's reading of each reading list item as last read (no backfill: filled at
            // the next read of the list).
            try db.alter(table: "kavitaReadingListItem") { t in
                t.add(column: "kavitaPagesRead", .integer)
                t.add(column: "kavitaPages", .integer)
                t.add(column: "kavitaReadAt", .datetime)
            }
        }

        migrator.registerMigration("v62_audio_mark_note") { db in
            // Kiku: a note on a mark (device-only, like the mark).
            try db.alter(table: "audioMark") { t in
                t.add(column: "note", .text)
            }
        }

        migrator.registerMigration("v63_book_fonts") { db in
            // Yomu: fonts the reader added for books (the files are in this device's container).
            try db.create(table: "bookFont") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("fileName", .text).notNull()
                t.column("addedAt", .datetime).notNull()
            }
        }

        migrator.registerMigration("v64_daily_goals") { db in
            // A daily goal per activity, kept as a history (each change from its day).
            try db.create(table: "dailyGoal") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("kind", .text).notNull()
                t.column("measure", .text).notNull()
                t.column("target", .integer).notNull()
                t.column("since", .datetime).notNull()
            }
        }

        migrator.registerMigration("v65_record_sync") { db in
            // Sync with iCloud (RecordSync): each synced record as last merged here.
            try db.create(table: "syncRecord") { t in
                t.column("collection", .text).notNull()
                t.column("id", .text).notNull()
                t.column("value", .blob)
                t.column("editedAt", .integer).notNull()
                t.column("deleted", .boolean).notNull().defaults(to: false)
                t.column("device", .text).notNull()
                t.primaryKey(["collection", "id"])
            }
        }

        migrator.registerMigration("v66_audio_mark_uuid") { db in
            // Kiku's marks with Sync with iCloud: an id that's the same on every device.
            try db.alter(table: "audioMark") { t in
                t.add(column: "uuid", .text)
            }
            try db.execute(sql: "UPDATE audioMark SET uuid = lower(hex(randomblob(16))) WHERE uuid IS NULL")
            try db.create(index: "audioMark_uuid", on: "audioMark", columns: ["uuid"], unique: true)
        }

        migrator.registerMigration("v67_up_next") { db in
            // Kiku's Up Next, per podcast library, as Audiobookshelf's "Up Next" playlist has it
            // (or will once the outbox sends it), and that playlist's id.
            try db.create(table: "upNextItem") { t in
                t.column("libraryId", .text).notNull()
                t.column("position", .integer).notNull()
                t.column("itemId", .text).notNull()
                t.column("episodeId", .text).notNull()
                t.column("title", .text).notNull()
                t.column("showTitle", .text).notNull()
                t.primaryKey(["libraryId", "position"])
            }
            try db.create(table: "upNextPlaylist") { t in
                t.primaryKey("libraryId", .text)
                t.column("playlistId", .text)
            }
        }

        migrator.registerMigration("v68_series_player_setting") { db in
            // Miru: a show's own player settings (Condensed), by series (or a movie's item) id.
            try db.create(table: "seriesPlayerSetting") { t in
                t.primaryKey("seriesKey", .text)
                t.column("condensed", .boolean).notNull().defaults(to: false)
            }
        }

        migrator.registerMigration("v69_character_names") { db in
            // The names dictionary (Packages/Names): casts by AniList media, which media each
            // series is, the series each app has open, and its switch.
            try db.create(table: "characterCast") { t in
                t.primaryKey("mediaKey", .text)
                t.column("title", .text).notNull()
                t.column("fetchedAt", .datetime).notNull()
                t.column("characters", .blob).notNull()
            }
            try db.create(table: "characterNameMatch") { t in
                t.primaryKey("seriesKey", .text)
                t.column("mediaKey", .text)
                t.column("source", .text).notNull()
                t.column("title", .text).notNull()
                t.column("matchedAt", .datetime).notNull()
            }
            try db.create(table: "characterNameOpenSeries") { t in
                t.primaryKey("app", .text)
                t.column("seriesKey", .text).notNull()
                t.column("openedAt", .datetime).notNull()
            }
            try db.create(table: "characterNameSettings") { t in
                t.primaryKey("id", .integer)
                t.column("enabled", .boolean).notNull().defaults(to: true)
            }
        }

        migrator.registerMigration("v70_read_along_source") { db in
            // Yomu: what made the transcript a read-along was aligned with (#149).
            try db.alter(table: "readAlongPair") { t in
                t.add(column: "transcriptModel", .text)
                t.add(column: "transcriptKaku", .text)
                t.add(column: "transcribedAt", .datetime)
            }
        }

        migrator.registerMigration("v71_demo_server") { db in
            // The public demo servers: nothing is written to them. Their jobs' kinds are held
            // (kept, unsent) while signed in, and discarded on leaving.
            try db.alter(table: "serverAccount") { t in
                t.add(column: "isDemo", .boolean).notNull().defaults(to: false)
            }
            try db.create(table: "outboxHeld") { t in
                t.primaryKey("kind", .text)
            }
        }

        return migrator
    }
}
