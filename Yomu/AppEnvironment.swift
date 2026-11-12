import Anki
import AppCommon
import AudiobookshelfKit
import Core
import Dictionary
import Foundation
import KavitaKit
import Lookup
import OCR
import Observation
import Readers

/// The Reader's services: the shared ones (`common`: storage, outbox, dictionaries,
/// lookup, mining) plus Kavita, the manga and book readers and OCR. Both this and
/// `common` are put in the SwiftUI environment; shared screens read `common`.
@Observable
final class AppEnvironment {
    let common: CommonEnvironment
    let pageCache: PageCacheStore
    let pages: MangaPageRepository
    let kavitaLibrary: KavitaLibraryRepository
    let readingProgress: ReadingProgressStore
    let readerSettings: MangaReaderSettingsStore
    let ocrModels: OCRModelStore
    let ocr: OCRService
    let books: BookRepository
    let bookSettings: BookReaderSettingsStore
    let libraryVisibility: LibraryVisibilityStore
    let downloader: VolumeDownloader
    let autoDownloads: AutoDownloadManager
    /// Read-along: Audiobookshelf sign-in (refreshed once for every client) and the pairs.
    let audiobookshelfTokens: AudiobookshelfTokens
    let readAlongPairs: ReadAlongStore
    /// Each EPUB volume's characters, for the library's progress (`BookLengthCounter`).
    let bookLengths: BookLengths
    @ObservationIgnored private var counter: BookLengthCounter?
    /// Counts Japanese books' characters (Settings ▸ Character Counts).
    var bookCounter: BookLengthCounter {
        if let counter { return counter }
        let made = BookLengthCounter(environment: self)
        counter = made
        return made
    }
    /// Where the read-along audio was, for resuming offline.
    let listenProgress: WatchProgressStore
    /// Libraries turned off in Settings → Libraries.
    private(set) var hiddenLibraries: Set<Int> = []
    /// The last Kavita refresh couldn't reach the server (the device may still be online).
    var kavitaUnreachable = false

    /// Offline or Kavita out of reach: the Library shows only series with downloads.
    var isLibraryOffline: Bool { !common.reachability.isOnline || kavitaUnreachable }

    /// Series with at least one volume on the device.
    var downloadedSeriesIds: Set<Int> {
        Set(downloader.records.values.filter { $0.state == .done }.compactMap { VolumeDownloader.extra($0)?.seriesId })
    }

    /// Records whether a Kavita refresh reached the server.
    func noteKavitaRefresh(error: (any Error)?) {
        switch error as? ConnectionError {
        case .unreachable?, .timeout?, .tls?: kavitaUnreachable = true
        default: if error == nil { kavitaUnreachable = false }
        }
    }
    /// The tab showing (menu shortcuts ⌘1–⌘4 switch it).
    var selectedTab = AppTab.library
    /// A library picked in the iPad's sidebar: the Library tab opens it.
    var requestedLibrary: KavitaLibrary?
    /// On the Mac, the volume being read in the main window (replacing the tabs while it's open).
    var readingSession: ReaderSession?
    /// A volume to open from a link (Kiku's Read in Yomu): the reader in front takes it, else
    /// the root view presents it.
    var requestedReader: ReaderSession?
    /// Whether a reader is showing (set by `ReaderContainer`).
    var readerIsOpen = false
    /// Why a link couldn't be opened.
    var linkProblem: String?
    /// Audiobook times from links, by item, for read-along to start at (once).
    @ObservationIgnored var linkedListening: [String: Double] = [:]
    @ObservationIgnored private var started = false

    // The shared services the Reader's own screens use.
    var database: AppDatabase { common.database }
    var secrets: any SecretStore { common.secrets }
    var accounts: AccountStore { common.accounts }
    var outbox: OutboxStore { common.outbox }
    var http: HTTPClient { common.http }
    var lookup: LookupService { common.lookup }
    var serverAccounts: [ServerKind: ServerAccount] { common.serverAccounts }
    var startupError: String? { common.startupError }
    func syncNow(retryWaiting: Bool = false) { common.syncNow(retryWaiting: retryWaiting) }

    init(
        database: AppDatabase, secrets: any SecretStore, mediaDirectory: URL, cacheDirectory: URL,
        dictionaryDirectory: URL, ocrModelDirectory: URL, startupError: String? = nil,
        sendsProgress: Bool = true, sendsCards: Bool = true, sharedSetup: SharedSetup? = nil
    ) {
        let http = HTTPClient()
        let tokens = AudiobookshelfTokens(secrets: secrets)
        audiobookshelfTokens = tokens
        common = CommonEnvironment(
            database: database, secrets: secrets, mediaDirectory: mediaDirectory, dictionaryDirectory: dictionaryDirectory,
            http: http, startupError: startupError, sendsCards: sendsCards, sharedSetup: sharedSetup,
            appHandlers: { context in
                guard sendsProgress else { return [] }
                return [
                    KavitaProgressHandler(makeClient: Self.kavitaClientFactory(accounts: context.accounts, secrets: context.secrets, http: context.http)),
                    // Read-along listening moves the audiobook's place too.
                    AudiobookshelfProgressHandler(makeClient: AudioServers.audiobookshelfClientFactory(
                        accounts: context.accounts, tokens: tokens, http: context.http)),
                ]
            }
        )
        // Yomu green (its AccentColor), with dark text on filled buttons.
        common.lookup.accent = ("#3FC98F", "#04261A")
        kavitaLibrary = KavitaLibraryRepository(database: database)
        readAlongPairs = ReadAlongStore(database: database)
        bookLengths = BookLengths(database: database)
        listenProgress = WatchProgressStore(database: database)
        readingProgress = ReadingProgressStore(database: database)
        readerSettings = MangaReaderSettingsStore(database: database)
        pageCache = PageCacheStore(database: database, directory: cacheDirectory.appending(path: "Pages"))
        ocrModels = OCRModelStore(directory: ocrModelDirectory)
        ocr = OCRService(cache: OCRCache(database: database), storeDirectory: ocrModelDirectory)

        let makeKavita = Self.kavitaClientFactory(accounts: common.accounts, secrets: secrets, http: http)
        pages = MangaPageRepository(cache: pageCache) { (try? makeKavita()).flatMap { $0 }.map(KavitaPageSource.init) }
        books = BookRepository(directory: cacheDirectory.appending(path: "Books")) { chapterId in
            guard let client = try makeKavita() else { throw BookRepository.BookError.unavailable }
            return try await client.downloadChapter(chapterId: chapterId)
        }
        bookSettings = BookReaderSettingsStore(database: database)
        libraryVisibility = LibraryVisibilityStore(database: database)
        downloader = VolumeDownloader(store: common.downloads, database: database, pages: pages, pageCache: pageCache,
                                      books: books, ocr: ocr, reachability: common.reachability)
        autoDownloads = AutoDownloadManager(store: AutoDownloadSettingsStore(database: database), library: kavitaLibrary,
                                            progress: readingProgress, downloader: downloader, reachability: common.reachability,
                                            makeClient: { (try? makeKavita()).flatMap { $0 } })
    }

    static func live() -> AppEnvironment {
        #if DEBUG
        if let uiTest = uiTest() { return uiTest }
        #endif
        let support = SetupTestData.support()
        let media = support.appending(path: "OutboxMedia")
        // Pages and books live in Application Support: iOS may purge Caches when storage is
        // low, which would take downloaded volumes with it. Not backed up (it's all on Kavita).
        let movedFromCaches = FileManager.default.fileExists(atPath: URL.cachesDirectory.appending(path: "Pages").path(percentEncoded: false))
        let caches = Self.readerStorage(support: support)
        let dictionaries = support.appending(path: "Dictionaries")
        let ocrModels = support.appending(path: "OCRModels")
        let secrets = SetupTestData.secrets(database: support.appending(path: "Database"))
        do {
            let database = try AppDatabase.onDisk(directory: support.appending(path: "Database"))
            #if DEBUG
            let sendsProgress = !DevSetup.holdsProgress()
            #else
            let sendsProgress = true
            #endif
            let environment = AppEnvironment(database: database, secrets: secrets, mediaDirectory: media,
                                             cacheDirectory: caches, dictionaryDirectory: dictionaries, ocrModelDirectory: ocrModels,
                                             sendsProgress: sendsProgress, sharedSetup: SetupTestData.sharedSetup())
            // The old cache folder is gone; drop its index rows so sizes are right.
            if movedFromCaches { try? environment.pageCache.clear() }
            #if DEBUG
            if DevSetup.isRequested {
                environment.common.setup.finish()
                Task { await environment.applyDevSetup() }
            }
            #endif
            return environment
        } catch {
            // Keep the app usable so the error can be seen; nothing written this session persists.
            return AppEnvironment(
                database: try! AppDatabase.inMemory(), secrets: secrets, mediaDirectory: media,
                cacheDirectory: caches, dictionaryDirectory: dictionaries, ocrModelDirectory: ocrModels,
                startupError: "Couldn't open the database: \(error.localizedDescription)"
            )
        }
    }

    /// The folder for pages and books, created and excluded from backup. Removes the
    /// cache folders used before downloads existed (only re-downloadable cache).
    private static func readerStorage(support: URL) -> URL {
        var folder = support.appending(path: "ReaderStorage", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
        for old in ["Pages", "Books"] {
            try? FileManager.default.removeItem(at: URL.cachesDirectory.appending(path: old))
        }
        return folder
    }

    #if DEBUG
    /// UI tests pass a Kavita server and/or dictionary zips through the environment.
    /// Everything lives in memory or a temporary folder and progress is never sent,
    /// so test runs can't change real data.
    private static func uiTest() -> AppEnvironment? {
        let env = ProcessInfo.processInfo.environment
        let kavitaURL = env["UITEST_KAVITA_URL"].flatMap { try? ServerURL.parse($0) }
        let kavitaKey = env["UITEST_KAVITA_KEY"]
        // Dictionaries and OCR models can be handed in without Kavita.
        // Paths separated by "|" (the simulator can read files the test runner wrote).
        let dictionaryZips = (env["UITEST_DICTIONARY_ZIPS"] ?? "").split(separator: "|").map { URL(filePath: String($0)) }
        guard (kavitaURL != nil && kavitaKey != nil) || !dictionaryZips.isEmpty || env["UITEST_STATS"] != nil else { return nil }
        let temp = URL.temporaryDirectory.appending(path: "UITest-\(UUID().uuidString)")
        // Cards are only sent when a test names a scratch deck; otherwise they stay queued.
        let ankiURL = env["UITEST_ANKI_URL"].flatMap { try? ServerURL.parse($0) }
        let ankiDeck = env["UITEST_ANKI_DECK"].flatMap { $0.isEmpty ? nil : $0 }
        let sendsCards = ankiURL != nil && ankiDeck != nil
        let environment = AppEnvironment(
            database: try! AppDatabase.inMemory(), secrets: InMemorySecretStore(kavitaKey.map { [.kavitaAuthKey: $0] } ?? [:]),
            mediaDirectory: temp.appending(path: "Media"), cacheDirectory: temp,
            dictionaryDirectory: temp.appending(path: "Dictionaries"),
            // OCR models are large: tests point at an installed copy rather than downloading.
            ocrModelDirectory: env["UITEST_OCR_MODELS"].map { URL(filePath: $0) } ?? temp.appending(path: "OCRModels"),
            sendsProgress: false, sendsCards: sendsCards
        )
        if let kavitaURL {
            try? environment.accounts.save(ServerAccount(kind: .kavita, baseURL: kavitaURL, serverName: "Kavita"))
        }
        // Read-along tests: Audiobookshelf (an API key) and Kaku. Only read from: progress isn't sent.
        if let url = env["UITEST_ABS_URL"].flatMap({ try? ServerURL.parse($0) }), let key = env["UITEST_ABS_KEY"] {
            try? environment.secrets.setSecret(key, for: .audiobookshelfToken)
            try? environment.accounts.save(ServerAccount(kind: .audiobookshelf, baseURL: url, serverName: "Audiobookshelf"))
        }
        if let url = env["UITEST_KAKU_URL"].flatMap({ try? ServerURL.parse($0) }), let token = env["UITEST_KAKU_TOKEN"] {
            try? environment.secrets.setSecret(token, for: .kakuAPIToken)
            try? environment.accounts.save(ServerAccount(kind: .kaku, baseURL: url, serverName: "Kaku"))
        }
        if sendsCards, let ankiURL, let ankiDeck {
            try? environment.accounts.save(ServerAccount(kind: .anki, baseURL: ankiURL, serverName: "AnkiConnect"))
            var settings = AnkiSettings.default
            settings.deck = ankiDeck
            settings.tags = ["amatsubame", "amatsubame-test"]
            try? environment.common.ankiSettings.save(settings)
        }
        environment.common.pendingDictionaryImports = dictionaryZips
        if env["UITEST_STATS"] != nil { seedStats(environment.common.activity, kind: .reading) }
        // In-memory UI tests start set up.
        environment.common.setup.finish()
        return environment
    }
    #endif

    #if DEBUG
    /// A simulator for hands-on testing (`DevSetup`): the shared pieces, Audiobookshelf and Kaku
    /// for read-along, Kavita (`DEV_KAVITA_URL/KEY`) and the hidden libraries (`DEV_HIDDEN_LIBRARIES`).
    private func applyDevSetup() async {
        await DevSetup.applyCommon(common)
        await DevSetup.applyAudioServers(common, tokens: audiobookshelfTokens)
        if let url = DevSetup.value("DEV_KAVITA_URL"), let key = DevSetup.value("DEV_KAVITA_KEY") {
            let model = KavitaSettingsModel(environment: common)
            model.urlText = url
            model.authKey = key
            await model.testAndSave()
            DevSetup.log("Kavita", model.status)
        }
        for id in DevSetup.list("DEV_HIDDEN_LIBRARIES").compactMap(Int.init) {
            try? libraryVisibility.setHidden(id, hidden: true)
        }
        DevSetup.log("Done")
    }
    #endif

    static func preview() -> AppEnvironment {
        AppEnvironment(
            database: try! AppDatabase.inMemory(), secrets: InMemorySecretStore(),
            mediaDirectory: URL.temporaryDirectory.appending(path: "OutboxMedia"),
            cacheDirectory: URL.temporaryDirectory.appending(path: "Caches"),
            dictionaryDirectory: URL.temporaryDirectory.appending(path: "PreviewDictionaries"),
            ocrModelDirectory: URL.temporaryDirectory.appending(path: "PreviewOCRModels")
        )
    }

    func start() async {
        guard !started else { return }
        started = true
        async let common: Void = common.start()
        async let hidden: Void = observeHiddenLibraries()
        async let downloads: Void = downloader.start()
        async let downloadSettings: Void = observeDownloadSettings()
        #if DEBUG
        queueDebugDownloads()
        // READER_TAB=stats (or library, dictionary, settings; "search" still works) opens on that tab (live checks).
        let tabName = ProcessInfo.processInfo.environment["READER_TAB"].map { $0 == "search" ? "dictionary" : $0 }
        if let tab = tabName.flatMap(AppTab.init(rawValue:)) { selectedTab = tab }
        #endif
        autoDownloads.schedule(after: 5)
        _ = await (common, hidden, downloads, downloadSettings)
    }

    /// Turning "Read Text on Downloaded Pages" back on picks up volumes still waiting for it.
    private func observeDownloadSettings() async {
        do {
            for try await _ in DownloadSettings.observe(database) {
                downloader.resumeTextReading()
            }
        } catch {}
    }

    private func observeHiddenLibraries() async {
        do {
            for try await value in libraryVisibility.observeHidden() {
                hiddenLibraries = value
            }
        } catch {}
    }

    #if DEBUG
    /// Live checks: READER_DOWNLOAD_CHAPTERS=<chapterId>:<seriesId>,… queues those downloads
    /// (series and volumes must be in the library cache).
    private func queueDebugDownloads() {
        let spec = ProcessInfo.processInfo.environment["READER_DOWNLOAD_CHAPTERS"] ?? ""
        for pair in spec.split(separator: ",") {
            let parts = pair.split(separator: ":").compactMap { Int($0) }
            guard parts.count == 2, let series = try? kavitaLibrary.cachedSeries(id: parts[1]),
                  let volumes = try? kavitaLibrary.cachedVolumes(seriesId: parts[1]) else { continue }
            for volume in volumes {
                for chapter in volume.chapters where chapter.id == parts[0] {
                    downloader.download(chapter, series: series, title: chapter.displayTitle(in: volume))
                }
            }
        }
        // READER_REMOVE_DOWNLOADS=<chapterId>,… (or "automatic") removes those downloads once loaded.
        let remove = ProcessInfo.processInfo.environment["READER_REMOVE_DOWNLOADS"] ?? ""
        guard !remove.isEmpty else { return }
        let ids = Set(remove.split(separator: ",").compactMap { Int($0) })
        Task {
            try? await Task.sleep(for: .seconds(2))
            for record in downloader.records.values {
                let automatic = VolumeDownloader.extra(record)?.isAutomatic == true
                if (remove == "automatic" && automatic) || ids.contains(Int(record.itemKey) ?? -1) {
                    await downloader.delete(record)
                }
            }
        }
    }
    #endif

    // MARK: Kavita and the readers

    /// Reads the saved account and key each time, so Settings changes apply immediately.
    private static func kavitaClientFactory(
        accounts: AccountStore, secrets: any SecretStore, http: HTTPClient
    ) -> @Sendable () throws -> KavitaClient? {
        {
            guard let account = try accounts.account(.kavita),
                  let key = try secrets.secret(for: .kavitaAuthKey) else { return nil }
            return KavitaClient(baseURL: account.baseURL, authKey: key, http: http)
        }
    }

    func kavitaClient() -> KavitaClient? {
        try? Self.kavitaClientFactory(accounts: accounts, secrets: secrets, http: http)()
    }

    // MARK: Read-along servers

    func audiobookshelfClient() -> AudiobookshelfClient? {
        try? AudioServers.audiobookshelfClientFactory(accounts: accounts, tokens: audiobookshelfTokens, http: http)()
    }

    func kakuClient() -> KakuClient? { AudioServers.kakuClient(common) }

    func makeReader(_ chapter: ReaderChapter, next: ReaderChapter?) -> MangaReaderModel {
        let model = MangaReaderModel(
            chapter: chapter, nextChapter: next, pages: pages, settingsStore: readerSettings,
            progressStore: readingProgress, outbox: outbox, ocr: ocr, lookup: lookup,
            syncNow: { [weak self] in self?.syncNow() }
        )
        model.activity = common.activity
        return model
    }

    func makeBookReader(_ chapter: ReaderChapter, next: ReaderChapter?) -> BookReaderModel {
        let makeKavita = Self.kavitaClientFactory(accounts: accounts, secrets: secrets, http: http)
        let http = http
        let model = BookReaderModel(
            chapter: chapter, nextChapter: next, repository: books, settingsStore: bookSettings,
            progressStore: readingProgress, outbox: outbox, lookup: lookup,
            serverProgress: { chapterId in
                guard let client = try makeKavita() else { throw BookRepository.BookError.unavailable }
                return try await client.progress(chapterId: chapterId)
            },
            chapterCover: { chapterId in
                guard let client = try? makeKavita() else { return nil }
                return try? await http.send(client.chapterCoverRequest(chapterId: chapterId)).data
            },
            syncNow: { [weak self] in self?.syncNow() }
        )
        model.activity = common.activity
        model.lengths = bookLengths
        #if DEBUG
        model.auditsPages = ProcessInfo.processInfo.environment["UITEST_BOOK_AUDIT"] != nil
        #endif
        // A paired, prepared book reads along with its audiobook.
        if let pair = try? readAlongPairs.pair(chapterId: chapter.chapterId), pair.alignmentVersion == ReadAlongCues.version,
           let data = pair.cues, let cues = ReadAlongCues(data: data), !cues.cues.isEmpty {
            // Off for this volume unless Kiku's Read in Yomu opened it, which turns it back on.
            let linked = linkedListening[pair.itemId] != nil
            if linked, !pair.readsAlong { try? readAlongPairs.setReadsAlong(chapterId: pair.chapterId, true) }
            model.readAlong = ReadAlongModel(pair: pair, cues: cues, reader: model, environment: self, isOn: pair.readsAlong || linked)
        }
        return model
    }
}

// MARK: Links

extension AppEnvironment {
    /// The scheme Kiku opens: `amatsubame-yomu://read-along?item=<Audiobookshelf item>&t=<seconds>`.
    static let linkSchemes: Set<String> = ["amatsubame-yomu"]

    /// Opens the volume paired with an audiobook at the time Kiku was playing: read-along takes
    /// the time when it starts (`linkedListening`) and opens at that sentence. No network is
    /// needed.
    func open(_ url: URL) {
        guard let scheme = url.scheme, Self.linkSchemes.contains(scheme), url.host() == "read-along",
              let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let itemId = query.first(where: { $0.name == "item" })?.value, !itemId.isEmpty else { return }
        let time = query.first { $0.name == "t" }?.value.flatMap(Double.init)
        let pairs = (try? readAlongPairs.pairs(itemId: itemId)) ?? []
        guard let session = pairs.lazy.compactMap({ self.session(chapterId: $0.chapterId) }).first else {
            linkProblem = pairs.isEmpty
                ? "This audiobook isn't paired with a book in Yomu yet. Open its EPUB volume and choose Read-Along ⋯ ▸ Pair with an Audiobook."
                : "The paired volume isn't in Yomu's library yet. Open the Library once while connected to Kavita."
            return
        }
        if let time { linkedListening[itemId] = time }
        selectedTab = .library
        requestedReader = session
    }

    /// A reader session for a volume, from the library cache.
    func session(chapterId: Int) -> ReaderSession? {
        guard let seriesId = try? kavitaLibrary.cachedSeriesId(chapterId: chapterId),
              let series = try? kavitaLibrary.cachedSeries(id: seriesId),
              let volumes = try? kavitaLibrary.cachedVolumes(seriesId: seriesId),
              let chapter = volumes.lazy.flatMap(\.chapters).first(where: { $0.id == chapterId }) else { return nil }
        let contents = KavitaSeriesContents(volumes: volumes)
        return ReaderSession(chapter: contents.readerChapter(chapter, series: series), series: series, contents: contents)
    }
}
