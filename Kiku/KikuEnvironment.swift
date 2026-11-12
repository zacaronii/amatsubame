import AVFoundation
import AppCommon
import AudiobookshelfKit
import Core
import Foundation
import Observation

/// Kiku's services: the shared ones (`common`: storage, outbox, dictionaries, lookup, mining)
/// plus Audiobookshelf, Kaku, listening progress and saved transcripts.
@Observable
final class KikuEnvironment {
    let common: CommonEnvironment
    /// Local listening positions (the same store Miru uses for watching), keyed "<item>/<episode>".
    let listenProgress: WatchProgressStore
    let transcripts: AudioTranscriptStore
    /// "Mark now, mine later": marks made while listening.
    let marks: AudioMarkStore
    /// The last mark made, for the player's brief "Marked 13:21".
    private(set) var lastMark: AudioMark?
    /// Shared by every Audiobookshelf client, so an expired token is refreshed once.
    let tokens: AudiobookshelfTokens
    /// The tab showing (⌘1–⌘4 switch it).
    var selectedTab = KikuTab.listen
    /// A library to open in the Listen tab (the iPad's and Mac's sidebar).
    var requestedLibrary: AudiobookshelfLibrary?
    /// Shows, new episodes and progress from Audiobookshelf, shared by the tabs.
    @ObservationIgnored private(set) lazy var library = PodcastLibrary(environment: self)
    /// The episode loaded in the player (the mini player shows it), and whether the full player is open.
    private(set) var playback: PlaybackModel?
    var showsPlayer = false
    /// Read in Yomu found no Yomu to open.
    var yomuMissing = false
    @ObservationIgnored private(set) var downloader: EpisodeDownloader!
    /// Downloaded episodes' audio, by episode key (UI tests swap in their own).
    @ObservationIgnored var localAudioFile: (_ key: String) -> URL? = { _ in nil }
    /// Shows with a downloaded episode (the Library's Downloaded filter).
    var downloadedShowIds: Set<String> { downloader.downloadedShowIds }
    @ObservationIgnored private var started = false

    init(database: AppDatabase, secrets: any SecretStore, mediaDirectory: URL, dictionaryDirectory: URL,
         downloadsDirectory: URL = URL.applicationSupportDirectory.appending(path: "Downloads"), backgroundDownloads: Bool = true,
         startupError: String? = nil, sendsProgress: Bool = true, sendsCards: Bool = true, sharedSetup: SharedSetup? = nil) {
        let tokens = AudiobookshelfTokens(secrets: secrets)
        self.tokens = tokens
        common = CommonEnvironment(
            database: database, secrets: secrets, mediaDirectory: mediaDirectory, dictionaryDirectory: dictionaryDirectory,
            startupError: startupError, sendsCards: sendsCards, sharedSetup: sharedSetup,
            appHandlers: { context in
                guard sendsProgress else { return [] }
                let makeClient = AudioServers.audiobookshelfClientFactory(accounts: context.accounts, tokens: tokens, http: context.http)
                return [AudiobookshelfProgressHandler(makeClient: makeClient)]
            }
        )
        // Kiku orange (its AccentColor), with dark brown text on filled buttons.
        common.lookup.accent = ("#F79A3E", "#3A1A05")
        listenProgress = WatchProgressStore(database: database)
        transcripts = AudioTranscriptStore(database: database)
        let marks = AudioMarkStore(database: database)
        self.marks = marks
        // Undoing a card mined from a mark leaves the mark waiting again.
        common.mining.onCancelled = { jobId in try? marks.setUnmined(jobId: jobId) }
        downloader = EpisodeDownloader(
            directory: downloadsDirectory, store: common.downloads, database: database, background: backgroundDownloads,
            makeClient: { [weak self] in self?.audiobookshelfClient() },
            saveTranscript: { [weak self] entry in await self?.fetchTranscriptForDownload(entry) })
        localAudioFile = { [weak self] key in self?.downloader.localFile(key: key) }
    }

    static func live() -> KikuEnvironment {
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
            let environment = KikuEnvironment(database: database, secrets: secrets, mediaDirectory: media,
                                              dictionaryDirectory: dictionaries, sendsProgress: sendsProgress,
                                              sharedSetup: SetupTestData.sharedSetup())
            #if DEBUG
            environment.applyDevSetup(ProcessInfo.processInfo.environment)
            if DevSetup.isRequested {
                environment.common.setup.finish()
                Task { await environment.applyTestingSetup() }
            }
            #endif
            return environment
        } catch {
            // Keep the app usable so the error can be seen; nothing written this session persists.
            return KikuEnvironment(database: try! AppDatabase.inMemory(), secrets: secrets, mediaDirectory: media,
                                   dictionaryDirectory: dictionaries,
                                   startupError: "Couldn't open the database: \(error.localizedDescription)")
        }
    }

    #if DEBUG
    /// UI tests run in memory (`UITEST_KIKU=1`) and never send progress or cards.
    private static func uiTest() -> KikuEnvironment? {
        let env = ProcessInfo.processInfo.environment
        guard env["UITEST_KIKU"] != nil else { return nil }
        let temp = URL.temporaryDirectory.appending(path: "UITest-\(UUID().uuidString)")
        let environment = KikuEnvironment(
            database: try! AppDatabase.inMemory(), secrets: InMemorySecretStore(),
            mediaDirectory: temp.appending(path: "Media"), dictionaryDirectory: temp.appending(path: "Dictionaries"),
            downloadsDirectory: temp.appending(path: "Downloads"), backgroundDownloads: false,
            sendsProgress: false, sendsCards: false
        )
        if env["UITEST_STATS"] != nil { seedStats(environment.common.activity, kind: .listening) }
        if env["UITEST_KIKU_PLAYER"] != nil { environment.openUITestEpisode() }
        if env["UITEST_KIKU_BOOK"] != nil { environment.openUITestEpisode(book: true) }
        environment.common.pendingDictionaryImports = (env["UITEST_DICTIONARY_ZIPS"] ?? "")
            .split(separator: "|").map { URL(filePath: String($0)) }
        // In-memory UI tests start set up.
        environment.common.setup.finish()
        return environment
    }

    /// UI tests: an episode (or a book with three chapters) with a saved transcript and a minute
    /// of silence as its downloaded audio, opened in the player (paused), without any server.
    private func openUITestEpisode(book: Bool = false) {
        let file = URL.temporaryDirectory.appending(path: "uitest-episode.caf")
        if let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1),
           let audio = try? AVAudioFile(forWriting: file, settings: format.settings),
           let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000 * 60) {
            buffer.frameLength = buffer.frameCapacity
            try? audio.write(from: buffer)
        }
        let json = ##"{"id":"ep","libraryItemId":"show","title":"#48 梅雨の楽しみ方","duration":60,"publishedAt":1793800000000,"audioFile":{"ino":"1","duration":60}}"##
        let bookJSON = ##"{"id":"book","libraryId":"books","mediaType":"book","media":{"metadata":{"title":"テストの本","authorName":"著者"},"duration":60,"chapters":[{"id":0,"start":0,"end":20,"title":"第一章 夢"},{"id":1,"start":20,"end":40,"title":"第二章 出会い"},{"id":2,"start":40,"end":60,"title":"第三章 再会"}],"tracks":[{"index":1,"ino":"1","startOffset":0,"duration":60,"mimeType":"audio/mp4"}]}}"##
        let entry: EpisodeEntry
        if book {
            guard let item = try? JSONDecoder().decode(AudiobookshelfItem.self, from: Data(bookJSON.utf8)),
                  let whole = AudiobookshelfEpisode.wholeBook(item) else { return }
            entry = EpisodeEntry(episode: whole, showTitle: "著者", progress: nil, book: item)
        } else {
            guard let episode = try? JSONDecoder().decode(AudiobookshelfEpisode.self, from: Data(json.utf8)) else { return }
            entry = EpisodeEntry(episode: episode, showTitle: "週末のんびり雑談室", progress: nil)
        }
        let episode = entry.episode
        // Long enough to scroll; the first lines are the ones the tests look at.
        let texts = ["ほんとにそうですね。", "駅前の本屋で先に見つけてた", "え、もう読んだんですか？", "雨の日の過ごし方を考えていくと", "みんなで相談して決めるんですけど"]
            + (1...20).map { "家でゆっくりしたい、その\($0)番目の理由です。" }
        let info = AudioTranscriptInfo(itemId: entry.itemId, episodeId: episode.id, showTitle: entry.showTitle, episodeTitle: episode.title,
                                       fingerprint: nil, duration: 60, savedAt: .now, lastPlayedAt: .now)
        try? transcripts.save(info, sentences: texts.enumerated().map { index, text in
            AudioSentence(key: info.key, position: index, start: Double(index * 2 + 1), end: Double(index * 2) + 2.5, text: text)
        })
        localAudioFile = { $0 == entry.id ? file : nil }
        play(entry, autoplay: false)
    }

    /// Live checks on a simulator: servers handed in at launch (KIKU_ABS_URL + KIKU_ABS_KEY,
    /// KIKU_KAKU_URL + KIKU_KAKU_TOKEN, and PLAYER_IMPORT_DICTIONARIES-style KIKU_IMPORT_DICTIONARIES),
    /// so nothing is typed into the app or written in the code.
    private func applyDevSetup(_ env: [String: String]) {
        if let url = env["KIKU_ABS_URL"].flatMap(URL.init(string:)), let key = env["KIKU_ABS_KEY"] {
            try? common.secrets.setSecret(key, for: .audiobookshelfToken)
            try? common.accounts.save(ServerAccount(kind: .audiobookshelf, baseURL: url, username: "dev", serverName: "Audiobookshelf"))
        }
        if let url = env["KIKU_KAKU_URL"].flatMap(URL.init(string:)), let token = env["KIKU_KAKU_TOKEN"] {
            try? common.secrets.setSecret(token, for: .kakuAPIToken)
            try? common.accounts.save(ServerAccount(kind: .kaku, baseURL: url, serverName: "Kaku"))
        }
        if let key = env["KIKU_OPEN_PAUSED"] {
            // Opens the player on "<item>/<episode>" (or a book's "<item>") without playing
            // (nothing is saved until it plays).
            Task { [weak self] in
                guard let self else { return }
                await library.refresh()
                let parts = key.split(separator: "/").map(String.init)
                if let entry = await entry(itemId: parts[0], episodeId: parts.count > 1 ? parts[1] : "", showTitle: "") {
                    play(entry, autoplay: false)
                }
            }
        }
        if let zips = env["KIKU_IMPORT_DICTIONARIES"] {
            common.pendingDictionaryImports = zips.split(separator: "|").map { URL(filePath: String($0)) }
        }
    }

    /// A simulator for hands-on testing (`DevSetup`): the shared pieces, Audiobookshelf, Kaku
    /// and the hidden Audiobookshelf libraries (`DEV_HIDDEN_LIBRARIES`).
    private func applyTestingSetup() async {
        await DevSetup.applyCommon(common)
        await DevSetup.applyAudioServers(common, tokens: tokens)
        let hidden = DevSetup.list("DEV_HIDDEN_LIBRARIES")
        if !hidden.isEmpty {
            var settings = ListenSettings.load(common.database)
            settings.hiddenLibraries = hidden
            try? settings.save(common.database)
        }
        DevSetup.log("Done")
    }
    #endif

    static func preview() -> KikuEnvironment {
        KikuEnvironment(database: try! AppDatabase.inMemory(), secrets: InMemorySecretStore(),
                        mediaDirectory: URL.temporaryDirectory.appending(path: "PreviewMedia"),
                        dictionaryDirectory: URL.temporaryDirectory.appending(path: "PreviewDictionaries"),
                        downloadsDirectory: URL.temporaryDirectory.appending(path: "PreviewDownloads"), backgroundDownloads: false)
    }

    func start() async {
        guard !started else { return }
        started = true
        async let common: Void = common.start()
        async let downloads: Void = downloader.start()
        _ = await (common, downloads)
    }

    /// After a network change or coming back to the app: tries again what couldn't reach
    /// Audiobookshelf or Kaku, instead of waiting for a pull to refresh or a relaunch.
    func retryConnections() {
        if library.isOffline || library.error != nil { Task { await library.refresh() } }
        playback?.retryAfterReconnect()
    }

    // MARK: Playing

    /// Opens the player on an episode (at `time`, or where you left off) and starts it.
    func play(_ entry: EpisodeEntry, at time: Double? = nil, autoplay: Bool = true) {
        if let playback, playback.key == entry.id {
            if let time { playback.audio.seek(to: time) }
            if !playback.audio.isPlaying { playback.audio.play() }
            showsPlayer = true
            return
        }
        playback?.close()
        let model = PlaybackModel(entry: entry, environment: self)
        playback = model
        showsPlayer = true
        Task { await model.start(at: time, autoplay: autoplay) }
    }

    /// Stops and forgets the episode (the mini player goes away).
    func stopPlayback() {
        playback?.close()
        playback = nil
        showsPlayer = false
    }

    /// Marks what's playing at its current position (the player, or the Action Button and Siri
    /// shortcut). Nil when nothing is loaded.
    @discardableResult
    func mark(_ source: AudioMark.Source) -> AudioMark? {
        guard let playback else { return nil }
        let entry = playback.entry
        guard let mark = try? marks.add(AudioMark(
            itemId: entry.itemId, episodeId: entry.episode.id, showTitle: entry.showTitle, episodeTitle: entry.episode.title,
            time: playback.audio.currentTime, createdAt: .now, source: source)) else { return nil }
        lastMark = mark
        return mark
    }

    /// Keeps a Kaku transcript on the device (for the player offline and Marks search).
    @discardableResult
    func saveTranscript(_ document: KakuTranscript, entry: EpisodeEntry, played: Bool) throws -> [AudioSentence] {
        try saveTranscript(document, itemId: entry.itemId, episodeId: entry.episode.id, showTitle: entry.showTitle,
                           episodeTitle: entry.episode.title, played: played)
    }

    /// The same from the ids and titles alone (a mark's episode, maybe offline).
    @discardableResult
    func saveTranscript(_ document: KakuTranscript, itemId: String, episodeId: String, showTitle: String, episodeTitle: String,
                        played: Bool) throws -> [AudioSentence] {
        let info = AudioTranscriptInfo(itemId: itemId, episodeId: episodeId, showTitle: showTitle,
                                       episodeTitle: episodeTitle, fingerprint: document.source.fingerprint,
                                       duration: document.source.duration, savedAt: .now, lastPlayedAt: played ? .now : nil)
        let sentences = document.sentences.enumerated().map { index, sentence in
            AudioSentence(key: info.key, position: index, start: sentence.start, end: sentence.end, text: sentence.text,
                          words: sentence.words.map { AudioSentence.Word(text: $0.text, start: $0.start, end: $0.end) })
        }
        try transcripts.save(info, sentences: sentences)
        return sentences
    }

    /// An episode to play from its ids: from the library (loading the show if needed), or
    /// rebuilt from its download when offline.
    func entry(itemId: String, episodeId: String, showTitle: String) async -> EpisodeEntry? {
        if let playback, playback.entry.itemId == itemId, playback.entry.episode.id == episodeId { return playback.entry }
        // A book: its details (chapters, tracks), fetched or the saved copy.
        if episodeId.isEmpty {
            if let book = await library.loadBook(itemId), let entry = library.entry(book: book) { return entry }
            return downloader.records[itemId].flatMap(downloadedEntry)
        }
        if library.showEpisodes[itemId] == nil { await library.loadShow(itemId) }
        if let episode = library.showEpisodes[itemId]?.first(where: { $0.id == episodeId }) {
            return library.entry(episode, showTitle: showTitle)
        }
        let key = AudiobookshelfProgress.key(itemId: itemId, episodeId: episodeId)
        return downloader.records[key].flatMap(downloadedEntry)
    }

    /// Finished downloads, newest episode first (what plays offline).
    var downloadedEntries: [EpisodeEntry] {
        downloader.records.values.filter { $0.state == .done }.compactMap(downloadedEntry)
            .sorted { ($0.episode.publishedAt ?? 0) > ($1.episode.publishedAt ?? 0) }
    }

    /// An episode rebuilt from what was saved with its download.
    private func downloadedEntry(_ record: DownloadRecord) -> EpisodeEntry? {
        guard let meta = EpisodeDownloader.metadata(record) else { return nil }
        let json: [String: Any] = ["id": meta.episodeId, "libraryItemId": meta.itemId, "title": meta.title,
                                   "duration": meta.duration ?? 0, "publishedAt": meta.publishedAt ?? 0,
                                   "audioFile": ["ino": meta.ino, "duration": meta.duration ?? 0]]
        guard let data = try? JSONSerialization.data(withJSONObject: json),
              let episode = try? JSONDecoder().decode(AudiobookshelfEpisode.self, from: data) else { return nil }
        // A book takes its saved details (chapters), when its page or the player loaded them once.
        let book = meta.episodeId.isEmpty ? library.bookDetails[meta.itemId] : nil
        return EpisodeEntry(episode: episode, showTitle: meta.showTitle, progress: library.progress[meta.key], book: book)
    }

    /// A downloaded episode takes its transcript along, if Kaku has it ready.
    private func fetchTranscriptForDownload(_ entry: EpisodeEntry) async {
        guard (try? transcripts.transcript(key: entry.id)) == nil, let kaku = kakuClient(),
              case .ready(let document)? = try? await kaku.transcript(itemId: entry.itemId, episodeId: entry.episode.id) else { return }
        try? saveTranscript(document, entry: entry, played: false)
    }

    // MARK: Servers

    func audiobookshelfClient() -> AudiobookshelfClient? {
        try? AudioServers.audiobookshelfClientFactory(accounts: common.accounts, tokens: tokens, http: common.http)()
    }

    /// Nil until Kaku's URL and token are saved in Settings.
    func kakuClient() -> KakuClient? { AudioServers.kakuClient(common) }
}
