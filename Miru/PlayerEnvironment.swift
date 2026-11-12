import AppCommon
import AudiobookshelfKit
import Core
import Foundation
import JellyfinKit
import JimakuKit
import Observation

/// The Player's services: the shared ones (`common`: storage, outbox, dictionaries,
/// lookup, mining) plus Jellyfin browsing, playback progress and library visibility.
@Observable
final class PlayerEnvironment {
    let common: CommonEnvironment
    let watchProgress: WatchProgressStore
    let libraryVisibility: JellyfinLibraryVisibilityStore
    /// Whether each series has Japanese audio (Japanese Audio Only libraries).
    let audioChecks: JellyfinAudioCheckStore
    let transcripts: TranscriptStore
    let segments: MediaSegmentStore
    /// Subtitles found on Jimaku, per item (saved to Jellyfin through the outbox when the user asks).
    let localSubtitles: LocalSubtitleStore
    /// Jimaku and the id mapper go through this (a canned transport in UI tests).
    @ObservationIgnored var subtitleSearchHTTP: HTTPClient
    let downloader: EpisodeDownloader
    let identity: JellyfinClientIdentity
    /// Libraries turned off in Settings → Libraries.
    private(set) var hiddenLibraries: Set<String> = []
    /// Libraries showing only movies and shows with a Japanese audio track.
    private(set) var japaneseOnlyLibraries: Set<String> = []
    /// The tab showing (menu shortcuts ⌘1–⌘4 switch it).
    var selectedTab = PlayerTab.watch
    /// A series (or a library, from the sidebar) to open in the Watch tab.
    var openSeriesRequest: JellyfinItem?
    /// The Jellyfin libraries, as the Watch tab last loaded them (the iPad's and Mac's sidebar).
    var libraries: [JellyfinItem] = []
    /// Mac: the video playing in the main window, covering the tabs (one window for
    /// all videos, not one per video). iPhone and iPad present it full screen instead.
    var playingSession: PlaybackSession?

    func openSeries(_ series: JellyfinItem) {
        selectedTab = .watch
        openSeriesRequest = series
    }
    @ObservationIgnored private var started = false

    init(database: AppDatabase, secrets: any SecretStore, mediaDirectory: URL, dictionaryDirectory: URL,
         downloadsDirectory: URL = URL.applicationSupportDirectory.appending(path: "Downloads"), backgroundDownloads: Bool = true,
         startupError: String? = nil, sendsProgress: Bool = true, sendsCards: Bool = true, sharedSetup: SharedSetup? = nil) {
        // Made here on the main actor (it reads the device name); the outbox handler sends off it.
        let identity = JellyfinIdentity.make(secrets: secrets)
        self.identity = identity
        common = CommonEnvironment(
            database: database, secrets: secrets, mediaDirectory: mediaDirectory, dictionaryDirectory: dictionaryDirectory,
            startupError: startupError, sendsCards: sendsCards, sharedSetup: sharedSetup,
            appHandlers: { context in
                guard sendsProgress else { return [] }
                let makeClient = Self.jellyfinClientFactory(
                    accounts: context.accounts, secrets: context.secrets, identity: identity, http: context.http)
                let subtitles = LocalSubtitleStore(database: database)
                return [
                    JellyfinProgressHandler(makeClient: makeClient),
                    JellyfinSubtitleHandler(makeClient: makeClient, didUpload: { itemId in
                        try? subtitles.markUploaded(itemId: itemId, at: Date())
                        Task { @MainActor in
                            NotificationCenter.default.post(name: .localSubtitleUploaded, object: itemId)
                        }
                    }),
                ]
            }
        )
        // Miru purple (its AccentColor), with dark text on filled buttons.
        common.lookup.accent = ("#B98AF5", "#22103A")
        watchProgress = WatchProgressStore(database: database)
        libraryVisibility = JellyfinLibraryVisibilityStore(database: database)
        audioChecks = JellyfinAudioCheckStore(database: database)
        transcripts = TranscriptStore(database: database)
        segments = MediaSegmentStore(database: database)
        localSubtitles = LocalSubtitleStore(database: database)
        subtitleSearchHTTP = common.http
        let makeClient = Self.jellyfinClientFactory(accounts: common.accounts, secrets: secrets, identity: identity, http: common.http)
        downloader = EpisodeDownloader(
            directory: downloadsDirectory, store: common.downloads, transcripts: transcripts, database: database,
            http: common.http, background: backgroundDownloads, makeClient: { (try? makeClient()) ?? nil })
    }

    static func live() -> PlayerEnvironment {
        #if DEBUG
        if let uiTest = uiTest() { return uiTest }
        #endif
        let support = SetupTestData.support()
        let media = support.appending(path: "OutboxMedia")
        let dictionaries = support.appending(path: "Dictionaries")
        let secrets = SetupTestData.secrets(database: support.appending(path: "Database"))
        do {
            let database = try AppDatabase.onDisk(directory: support.appending(path: "Database"))
            #if DEBUG
            let sendsProgress = !DevSetup.holdsProgress()
            #else
            let sendsProgress = true
            #endif
            let environment = PlayerEnvironment(database: database, secrets: secrets, mediaDirectory: media,
                                                dictionaryDirectory: dictionaries, sendsProgress: sendsProgress,
                                                sharedSetup: SetupTestData.sharedSetup())
            #if DEBUG
            if DevSetup.isRequested {
                environment.common.setup.finish()
                Task { await environment.applyDevSetup() }
            }
            // Live checks: PLAYER_IMPORT_DICTIONARIES="<zip>|<zip>" (inside the app's container on Mac).
            if let zips = ProcessInfo.processInfo.environment["PLAYER_IMPORT_DICTIONARIES"] {
                environment.common.pendingDictionaryImports = zips.split(separator: "|").map { URL(filePath: String($0)) }
            }
            #endif
            return environment
        } catch {
            // Keep the app usable so the error can be seen; nothing written this session persists.
            return PlayerEnvironment(database: try! AppDatabase.inMemory(), secrets: secrets, mediaDirectory: media,
                                     dictionaryDirectory: dictionaries,
                                     startupError: "Couldn't open the database: \(error.localizedDescription)")
        }
    }

    #if DEBUG
    /// UI tests run in memory (`UITEST_PLAYER=1`), optionally with dictionary zips, and never send cards.
    private static func uiTest() -> PlayerEnvironment? {
        let env = ProcessInfo.processInfo.environment
        guard env["UITEST_PLAYER"] != nil else { return nil }
        let temp = URL.temporaryDirectory.appending(path: "UITest-\(UUID().uuidString)")
        let environment = PlayerEnvironment(
            database: try! AppDatabase.inMemory(), secrets: InMemorySecretStore(),
            mediaDirectory: temp.appending(path: "Media"), dictionaryDirectory: temp.appending(path: "Dictionaries"),
            downloadsDirectory: temp.appending(path: "Downloads"), backgroundDownloads: false,
            sendsProgress: false, sendsCards: false
        )
        if env["UITEST_TRANSCRIPT"] != nil {
            // A saved transcript, so Lines can be tested without Jellyfin.
            try? environment.transcripts.save(
                TranscriptInfo(itemId: "uitest-1", seriesId: nil, seriesName: "UI Test Show", title: "Pilot", season: 1, episode: 1,
                               mediaSourceId: "m", streamIndex: 1, runtime: 1400, lastPlayedAt: Date(), savedAt: Date()),
                lines: [(1, 3, "吾輩は猫である。"), (4, 6, "名前はまだ無い。"), (7, 9, "どこで生れたか\nとんと見当がつかぬ。")])
        }
        if env["UITEST_STATS"] != nil { seedStats(environment.common.activity, kind: .watching) }
        if env["UITEST_JIMAKU"] != nil {
            // Subtitle search against canned Jimaku answers, with a key already set.
            try? environment.common.secrets.setSecret("uitest", for: .jimakuAPIKey)
            environment.subtitleSearchHTTP = HTTPClient(transport: UITestJimakuTransport())
        }
        environment.common.pendingDictionaryImports = (env["UITEST_DICTIONARY_ZIPS"] ?? "")
            .split(separator: "|").map { URL(filePath: String($0)) }
        // In-memory UI tests start set up.
        environment.common.setup.finish()
        return environment
    }
    #endif

    #if DEBUG
    /// A simulator for hands-on testing (`DevSetup`): the shared pieces, Kaku, Jellyfin
    /// (`DEV_JELLYFIN_URL/USER/PASSWORD`) and the hidden libraries (`DEV_HIDDEN_LIBRARIES`).
    private func applyDevSetup() async {
        await DevSetup.applyCommon(common)
        await DevSetup.applyAudioServers(common, tokens: nil)
        if let url = DevSetup.value("DEV_JELLYFIN_URL"), let user = DevSetup.value("DEV_JELLYFIN_USER") {
            let model = JellyfinSettingsModel(environment: common)
            model.urlText = url
            model.username = user
            model.password = DevSetup.value("DEV_JELLYFIN_PASSWORD") ?? ""
            await model.signIn()
            DevSetup.log("Jellyfin", model.status)
        }
        for id in DevSetup.list("DEV_HIDDEN_LIBRARIES") {
            try? libraryVisibility.setHidden(id, hidden: true)
        }
        DevSetup.log("Done")
    }
    #endif

    static func preview() -> PlayerEnvironment {
        PlayerEnvironment(database: try! AppDatabase.inMemory(), secrets: InMemorySecretStore(),
                          mediaDirectory: URL.temporaryDirectory.appending(path: "PreviewMedia"),
                          dictionaryDirectory: URL.temporaryDirectory.appending(path: "PreviewDictionaries"),
                          downloadsDirectory: URL.temporaryDirectory.appending(path: "PreviewDownloads"), backgroundDownloads: false)
    }

    func start() async {
        guard !started else { return }
        started = true
        async let common: Void = common.start()
        async let hidden: Void = observeHiddenLibraries()
        async let japaneseOnly: Void = observeJapaneseOnlyLibraries()
        async let downloads: Void = downloader.start()
        _ = await (common, hidden, japaneseOnly, downloads)
    }

    private func observeHiddenLibraries() async {
        do {
            for try await value in libraryVisibility.observeHidden() {
                hiddenLibraries = value
            }
        } catch {}
    }

    private func observeJapaneseOnlyLibraries() async {
        do {
            for try await value in libraryVisibility.observeJapaneseOnly() {
                japaneseOnlyLibraries = value
            }
        } catch {}
    }

    // MARK: Jellyfin

    /// Reads the saved account and token each time, so Settings changes apply immediately.
    /// Nil until signed in.
    private static func jellyfinClientFactory(
        accounts: AccountStore, secrets: any SecretStore, identity: JellyfinClientIdentity, http: HTTPClient
    ) -> @Sendable () throws -> JellyfinClient? {
        {
            guard let account = try accounts.account(.jellyfin), let userId = account.userId,
                  let token = try secrets.secret(for: .jellyfinAccessToken) else { return nil }
            return JellyfinClient(baseURL: account.baseURL, identity: identity,
                                  accessToken: token, userId: userId, http: http)
        }
    }

    /// Mined cards get the line as an animated GIF (Settings ▸ Watching ▸ Card Picture).
    var animatedCardPictures: Bool { PlayerSettings.load(common.database).cardPicture == .animated }

    /// Nil until a Jimaku API key is saved in Settings.
    func jimakuClient() -> JimakuClient? {
        guard let key = try? common.secrets.secret(for: .jimakuAPIKey), !key.isEmpty else { return nil }
        return JimakuClient(apiKey: key, http: subtitleSearchHTTP)
    }

    var animeIdMapper: AnimeIdMapper { AnimeIdMapper(http: subtitleSearchHTTP) }

    /// Kaku, for subtitles Jimaku lacks (its own sign-in until the apps can share one).
    func kakuClient() -> KakuClient? { AudioServers.kakuClient(common) }

    func jellyfinClient() -> JellyfinClient? {
        try? Self.jellyfinClientFactory(accounts: common.accounts, secrets: common.secrets, identity: identity, http: common.http)()
    }
}

#if DEBUG
/// UI tests: Jimaku as if it had one show with two files for any episode (one SRT, one RAR).
private struct UITestJimakuTransport: HTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let path = request.url?.path() ?? ""
        let body: String
        if path.hasSuffix("/api/v2/ids") {
            body = #"{"anidb":1,"anilist":100}"#
        } else if path.hasSuffix("/api/entries/search") {
            body = #"[{"id":7,"name":"UI Test Show","japanese_name":"テスト","anilist_id":100,"flags":{"anime":true}}]"#
        } else if path.hasSuffix("/files") {
            body = #"[{"name":"UI Test Show 01.srt","url":"https://jimaku.cc/entry/7/download/a.srt","size":120},{"name":"UI Test Show 01-12.rar","url":"https://jimaku.cc/entry/7/download/b.rar","size":9000}]"#
        } else {
            body = "1\n00:00:00,500 --> 00:00:20,000\n吾輩は猫である。\n\n2\n00:00:20,500 --> 00:00:40,000\n名前はまだ無い。\n\n3\n00:00:41,000 --> 00:00:59,000\nどこで生れたかとんと見当がつかぬ。\n"
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        return (Data(body.utf8), response)
    }
}
#endif
