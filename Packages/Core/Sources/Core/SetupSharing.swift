import Foundation

/// Whether this app uses the setup shared with the other apps (dictionaries, audio sources,
/// AnkiConnect) or its own, decided at launch. Switching takes effect the next time the app
/// opens, since the dictionaries and lookup are created once.
public struct SetupSharing: Sendable {
    public enum Mode: String, Sendable {
        case shared, own
    }

    /// The setup this launch uses.
    public struct Resolved: Sendable {
        public var mode: Mode
        public var database: AppDatabase
        public var dictionaryDirectory: URL
        /// Both this app and the shared setup had a setup when sharing became possible: the
        /// user chooses (until then the app keeps its own).
        public var needsChoice: Bool

        public init(mode: Mode, database: AppDatabase, dictionaryDirectory: URL, needsChoice: Bool) {
            self.mode = mode
            self.database = database
            self.dictionaryDirectory = dictionaryDirectory
            self.needsChoice = needsChoice
        }
    }

    public let shared: SharedSetup
    public let sharedDatabase: AppDatabase
    public let own: (database: AppDatabase, dictionaries: URL)
    let ownSecrets: any SecretStore
    let sharedSecrets: any SecretStore
    nonisolated(unsafe) let defaults: UserDefaults
    /// Where the choice is kept: the app's own defaults, or (Hiku, whose extension
    /// must see it) the App Group's, under its own key.
    let preferenceKey: String
    /// The name it's listed under in the shared setup's members.
    let appName: String

    public init(shared: SharedSetup, sharedDatabase: AppDatabase, own: (database: AppDatabase, dictionaries: URL),
                ownSecrets: any SecretStore, sharedSecrets: any SecretStore, defaults: UserDefaults = .standard,
                preferenceKey: String = "setupSharing",
                appName: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "another app") {
        self.shared = shared
        self.sharedDatabase = sharedDatabase
        self.own = own
        self.ownSecrets = ownSecrets
        self.sharedSecrets = sharedSecrets
        self.defaults = defaults
        self.preferenceKey = preferenceKey
        self.appName = appName
    }

    /// The user's choice, if made.
    public var preference: Mode? {
        defaults.string(forKey: preferenceKey).flatMap(Mode.init)
    }

    /// First launch with the App Group: a new app fills in from the shared setup, the first
    /// set-up app publishes its own, and an app with its own setup next to a shared one asks.
    public func resolve() throws -> Resolved {
        if preference == nil {
            let sharedEmpty = try SharedSetup.isEmpty(sharedDatabase), ownEmpty = try SharedSetup.isEmpty(own.database)
            switch (sharedEmpty, ownEmpty) {
            case (true, false):
                try publish()
                save(.shared)
            case (false, false):
                return resolved(.own, needsChoice: true)
            default:
                save(.shared)
            }
        }
        let mode = preference ?? .own
        shared.noteMember(app: appName, sharing: mode == .shared)
        return resolved(mode, needsChoice: false)
    }

    /// The user's choice: use the shared setup (this app's own stays on disk, unused).
    public func useShared() {
        save(.shared)
    }

    /// The user's choice: keep this app's own setup, and stop sharing.
    public func keepOwn() {
        save(.own)
    }

    /// Turn sharing off: this app gets its own copy of the shared setup.
    public func leave() throws {
        try SharedSetup.copy(from: (sharedDatabase, shared.dictionaryDirectory), to: own)
        for key in RoutingSecretStore.sharedKeys {
            try? ownSecrets.setSecret(try sharedSecrets.secret(for: key), for: key)
        }
        save(.own)
    }

    /// Turn sharing on: an empty shared setup takes this app's; otherwise this app uses the shared one.
    public func join() throws {
        if try SharedSetup.isEmpty(sharedDatabase) { try publish() }
        save(.shared)
    }

    private func publish() throws {
        try SharedSetup.copy(from: own, to: (sharedDatabase, shared.dictionaryDirectory))
        shared.noteOrigin(app: appName)
        for key in RoutingSecretStore.sharedKeys {
            try? sharedSecrets.setSecret(try ownSecrets.secret(for: key), for: key)
        }
        SharedSetup.postChanged()
    }

    private func save(_ mode: Mode) {
        defaults.set(mode.rawValue, forKey: preferenceKey)
        shared.noteMember(app: appName, sharing: mode == .shared)
    }

    private func resolved(_ mode: Mode, needsChoice: Bool) -> Resolved {
        mode == .shared
            ? Resolved(mode: .shared, database: sharedDatabase, dictionaryDirectory: shared.dictionaryDirectory, needsChoice: needsChoice)
            : Resolved(mode: .own, database: own.database, dictionaryDirectory: own.dictionaries, needsChoice: needsChoice)
    }
}
