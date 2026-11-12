import Anki
import Core
import Dictionary
import Foundation
import GRDB
import KechimochiKit
import Lookup
import Observation
#if canImport(UIKit)
import UIKit
#endif

/// The services every app shares, created once at launch: storage, the outbox, the
/// dictionaries and lookup, Anki mining. Each app wraps this with its own services and
/// injects both into the SwiftUI environment; shared screens read this one.
@Observable
public final class CommonEnvironment {
    public let database: AppDatabase
    public let secrets: any SecretStore
    public let accounts: AccountStore
    public let outbox: OutboxStore
    public let worker: OutboxWorker
    public let reachability = Reachability()
    public let http: HTTPClient
    public let dictionaries: DictionaryLibrary
    public let lookup: LookupService
    /// The recommended dictionaries and their updates.
    public let dictionaryUpdater: DictionaryUpdater
    /// First-launch setup (per app).
    public let setup = SetupProgress(defaults: SetupTestData.defaults)
    public let ankiSettings: AnkiSettingsStore
    public let minedWords: MinedWordStore
    /// What the user chose to keep on the device (each app fills it with its own kind).
    public let downloads: DownloadStore
    public let mining: MiningService
    /// Reading, watching and lookups for the Stats tab.
    public let activity: ActivityLog
    /// Words in subtitle and transcript lines, marked by their state in the mining deck.
    public let wordMarks: WordMarkCache
    public let ankiSync: AnkiSyncScheduler
    public let outboxMedia: OutboxMediaStorage

    /// Set when the on-disk database couldn't be opened and the app fell back to memory.
    public let startupError: String?
    public private(set) var outboxSummary = OutboxSummary.empty
    public private(set) var serverAccounts: [ServerKind: ServerAccount] = [:]
    /// The saved accounts have been read (until then `serverAccounts` is empty, not unset).
    public private(set) var accountsLoaded = false
    /// Sharing the setup with the other apps (nil without the App Group).
    public let setupSharing: SetupSharing?
    /// What this launch uses (nil without the App Group).
    public let setupMode: SetupSharing.Mode?
    /// This app and the shared setup both had a setup: the user picks one in Settings.
    public private(set) var setupNeedsChoice = false
    /// The user switched; it applies the next time the app opens.
    public private(set) var setupSwitchPending = false
    private var ownAccounts: [ServerKind: ServerAccount] = [:]
    private var sharedAccounts: [ServerKind: ServerAccount] = [:]
    @ObservationIgnored private var setupObservation: SharedSetup.ChangeObservation?
    @ObservationIgnored private var loadedDictionaries: [DictionaryRecord] = []
    /// Dictionary zips to import at launch (UI tests only).
    @ObservationIgnored public var pendingDictionaryImports: [URL] = []
    @ObservationIgnored private var started = false

    /// What an app's own outbox handlers (e.g. reading or watch progress) are built from.
    public struct HandlerContext {
        public let accounts: AccountStore
        public let secrets: any SecretStore
        public let http: HTTPClient
    }

    /// - Parameters:
    ///   - appHandlers: the app's own outbox handlers; cards are handled here when `sendsCards`.
    ///   - sendsCards: false in UI tests unless a scratch deck is configured.
    ///   - sharedSetup: the App Group's shared setup, when available (`SharedSetup.inAppGroup()`).
    public init(
        database: AppDatabase, secrets: any SecretStore, mediaDirectory: URL, dictionaryDirectory: URL,
        http: HTTPClient = HTTPClient(), startupError: String? = nil, sendsCards: Bool = true,
        sharedSetup: SharedSetup? = nil, sharedSecrets: (any SecretStore)? = nil,
        setupPreference: (defaults: UserDefaults, key: String) = (SetupTestData.defaults, "setupSharing"),
        appHandlers: (HandlerContext) -> [any OutboxHandler] = { _ in [] }
    ) {
        self.database = database
        self.http = http
        self.startupError = startupError
        // Dictionaries, audio sources and AnkiConnect come from the shared setup when this app shares it.
        var setupDatabase = database, setupDictionaries = dictionaryDirectory
        var routedSecrets: any SecretStore = secrets
        var sharedAccountsDatabase: AppDatabase?
        if let sharedSetup, let sharedDatabase = try? sharedSetup.openDatabase() {
            let sharedSecrets = sharedSecrets
                ?? KeychainSecretStore(service: SetupTestData.sharedKeychainService, accessGroup: SharedSetup.groupIdentifier)
            let sharing = SetupSharing(shared: sharedSetup, sharedDatabase: sharedDatabase, own: (database, dictionaryDirectory),
                                       ownSecrets: secrets, sharedSecrets: sharedSecrets,
                                       defaults: setupPreference.defaults, preferenceKey: setupPreference.key, appName: Self.appName)
            let resolved = (try? sharing.resolve())
                ?? .init(mode: .own, database: database, dictionaryDirectory: dictionaryDirectory, needsChoice: false)
            setupSharing = sharing
            setupMode = resolved.mode
            setupNeedsChoice = resolved.needsChoice
            if resolved.mode == .shared {
                setupDatabase = sharedDatabase
                setupDictionaries = sharedSetup.dictionaryDirectory
                routedSecrets = RoutingSecretStore(own: secrets, shared: sharedSecrets)
                sharedAccountsDatabase = sharedDatabase
            }
        } else {
            setupSharing = nil
            setupMode = nil
        }
        self.secrets = routedSecrets
        let secrets = routedSecrets
        accounts = AccountStore(database: database, shared: sharedAccountsDatabase)
        outbox = OutboxStore(database: database)
        #if os(iOS)
        let lowMemoryImport = true
        #else
        let lowMemoryImport = false
        #endif
        dictionaries = DictionaryLibrary(database: setupDatabase, directory: setupDictionaries, lowMemoryImport: lowMemoryImport)
        lookup = LookupService(library: dictionaries, audio: AudioService(database: setupDatabase, http: http, secrets: routedSecrets), history: database)
        dictionaryUpdater = DictionaryUpdater(library: dictionaries, lookup: lookup, reachability: reachability)
        activity = ActivityLog(database: database)
        lookup.activity = activity
        ankiSettings = AnkiSettingsStore(database: setupDatabase)
        minedWords = MinedWordStore(database: setupDatabase)
        downloads = DownloadStore(database: database)
        outboxMedia = OutboxMediaStorage(directory: mediaDirectory)

        let audio = lookup.audio
        let ankiSettings = ankiSettings
        let makeAnki = Self.ankiClientFactory(accounts: accounts, secrets: secrets, http: http)
        ankiSync = AnkiSyncScheduler(makeClient: makeAnki, isEnabled: { (try? ankiSettings.settings().syncAfterAdding) ?? false })
        var handlers = appHandlers(HandlerContext(accounts: accounts, secrets: secrets, http: http))
        if sendsCards {
            handlers.append(AnkiNoteHandler(
                makeClient: makeAnki,
                settings: { try ankiSettings.settings() },
                fetchAudio: { term, reading in
                    await audio.firstClip(term: term, reading: reading).map { AudioClip(data: $0.data, fileExtension: $0.fileExtension) }
                },
                minedWords: minedWords,
                syncScheduler: ankiSync
            ))
        }
        worker = OutboxWorker(store: outbox, mediaStorage: outboxMedia, handlers: handlers)
        let worker = worker
        mining = MiningService(outbox: outbox, media: outboxMedia, settings: ankiSettings, minedWords: minedWords,
                               onQueued: { Task { await worker.drain() } })
        lookup.mining = mining
        wordMarks = WordMarkCache(service: lookup)
    }

    /// Starts syncing and loads the dictionaries; then keeps observing the queue and accounts
    /// (it doesn't return while the app runs).
    public func start() async {
        guard !started else { return }
        started = true
        reachability.onBecameOnline = { [weak self] in self?.syncNow(retryWaiting: true) }
        reachability.start()
        try? await worker.recover()
        syncNow()

        try? lookup.audio.installDefaultSourcesIfNeeded()
        try? lookup.audio.moveKeysToKeychain()
        for zip in pendingDictionaryImports {
            _ = try? await dictionaries.importDictionary(at: zip)
        }
        pendingDictionaryImports = []
        try? await lookup.reload()
        loadedDictionaries = (try? dictionaries.dictionaries()) ?? []
        dictionaryUpdater.start()
        Task {
            // At launch, then every 30 minutes while the app runs (word marks follow reviews in Anki).
            while !Task.isCancelled {
                await refreshMinedWords()
                try? await Task.sleep(for: .seconds(30 * 60))
            }
        }
        if setupMode == .shared { startSharingSetup() }

        async let summary: Void = observe(outbox.observeSummary()) { $0.outboxSummary = $1 }
        async let own: Void = observe(accounts.observeAll()) { $0.ownAccounts = $1; $0.mergeAccounts(); $0.accountsLoaded = true }
        async let shared: Void = observe(accounts.observeShared()) { $0.sharedAccounts = $1; $0.mergeAccounts() }
        _ = await (summary, own, shared)
    }

    private func mergeAccounts() {
        serverAccounts = ownAccounts.merging(sharedAccounts) { _, shared in shared }
    }

    // MARK: Shared setup

    /// Tells the other apps when this one changes the dictionaries, and reloads when they do
    /// (or when the app comes back to the front).
    private func startSharingSetup() {
        setupObservation = SharedSetup.observeChanges { [weak self] in
            Task { @MainActor in await self?.reloadDictionariesIfChanged() }
        }
        let changes = dictionaries.database.changes(to: SharedSetup.reloadTables)
        Task {
            for await _ in changes { SharedSetup.postChanged() }
        }
        #if canImport(UIKit)
        NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            NotificationCenter.default.post(name: Database.resumeNotification, object: nil)
            Task { @MainActor in await self?.reloadDictionariesIfChanged() }
        }
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            // The shared database lives in the App Group: release its locks while suspended.
            NotificationCenter.default.post(name: Database.suspendNotification, object: nil)
        }
        #endif
    }

    private func reloadDictionariesIfChanged() async {
        let current = (try? dictionaries.dictionaries()) ?? []
        guard current != loadedDictionaries else { return }
        loadedDictionaries = current
        try? await lookup.reload()
    }

    /// The user's choice when both this app and the shared setup had one (applies next launch).
    public func chooseSharedSetup(_ useShared: Bool) {
        if useShared { setupSharing?.useShared() } else { setupSharing?.keepOwn() }
        setupNeedsChoice = false
        setupSwitchPending = useShared
    }

    /// The "Share setup with my other apps" switch (applies next launch).
    public func setSharingSetup(_ on: Bool) throws {
        guard let setupSharing else { return }
        if on { try setupSharing.join() } else { try setupSharing.leave() }
        setupSwitchPending = (on ? SetupSharing.Mode.shared : .own) != setupMode
    }

    private func observe<Value: Sendable>(
        _ values: AsyncThrowingStream<Value, any Error>,
        assign: @MainActor (CommonEnvironment, Value) -> Void
    ) async {
        do {
            for try await value in values {
                assign(self, value)
            }
        } catch {}
    }

    /// Sends what's due. `retryWaiting` also skips the backoff of jobs that failed
    /// (the user asked to sync, or the connection came back).
    public func syncNow(retryWaiting: Bool = false) {
        if retryWaiting { _ = try? outbox.retryWaitingNow() }
        Task { await worker.drain() }
    }

    // MARK: Anki

    /// Reads the saved account and key each time, so Settings changes apply immediately.
    private static func ankiClientFactory(
        accounts: AccountStore, secrets: any SecretStore, http: HTTPClient
    ) -> @Sendable () throws -> AnkiConnectClient? {
        {
            guard let account = try accounts.account(.anki) else { return nil }
            return AnkiConnectClient(baseURL: account.baseURL, apiKey: try secrets.secret(for: .ankiAPIKey), http: http)
        }
    }

    public func ankiClient() -> AnkiConnectClient? {
        try? Self.ankiClientFactory(accounts: accounts, secrets: secrets, http: http)()
    }

    /// Reloads which words are already in Anki, for the popup's marks. Quietly does nothing offline.
    public func refreshMinedWords() async {
        guard let client = ankiClient() else { return }
        try? await mining.refreshMinedWords(using: client)
    }

    // MARK: App info

    /// The app's name ("Yomu"), for wording that names it.
    /// The other apps using the shared setup (each records its choice when it opens).
    public var appsSharingSetup: [String] {
        guard setupMode == .shared, let members = setupSharing?.shared.members else { return [] }
        return ["Yomu", "Miru", "Kiku", "Hiku"].filter { $0 != Self.appName && members[$0] == true }
    }

    public static var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "This app"
    }

    /// Settings' status chip: whether kechimochi answers (a read-only call).
    public func checkKechimochi() async throws {
        _ = try await kechimochiClient()?.version()
    }

    /// kechimochi's API, on the same host as the page set in Settings ▸ Stats.
    func kechimochiClient() -> KechimochiClient? {
        guard let address = (try? activity.kechimochiURL()) ?? nil, let webURL = URL(string: address),
              var components = URLComponents(url: webURL, resolvingAgainstBaseURL: false) else { return nil }
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url.map { KechimochiClient(baseURL: $0, http: http) }
    }

    public static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    public static var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }
}
