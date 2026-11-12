import AppCommon
import Core
import Foundation

/// Hiku's services, the same for the app and its Safari extension: with the App
/// Group both open the same folder and follow the same "share setup" choice; without it each
/// process has its own (the extension's is the one that matters then).
@MainActor
public enum BrowserEnvironment {
    /// Hiku's accent, from its icon (#EE4F6B), with a dark ink for text on it.
    static let accent = (color: "#EE4F6B", onColor: "#3A0A1E")

    public static func make() -> CommonEnvironment {
        let environment = makeEnvironment()
        environment.lookup.accent = accent
        // Its own setup is the extension's built-in dictionaries: never updated from here.
        environment.dictionaryUpdater.isEnabled = environment.setupMode == .shared
        return environment
    }

    private static func makeEnvironment() -> CommonEnvironment {
        let location = BrowserStorage.location()
        let accessGroup = location.isShared ? SharedSetup.groupIdentifier : nil
        let secrets = KeychainSecretStore(service: BrowserStorage.keychainService, accessGroup: accessGroup)
        let media = location.root.appending(path: "OutboxMedia")
        let dictionaries = location.root.appending(path: "Dictionaries")
        let defaults = location.isShared ? UserDefaults(suiteName: SharedSetup.groupIdentifier) ?? .standard : .standard
        do {
            let database = try AppDatabase.onDisk(directory: location.root.appending(path: "Database"), shared: location.isShared)
            return CommonEnvironment(database: database, secrets: secrets, mediaDirectory: media, dictionaryDirectory: dictionaries,
                                     sharedSetup: location.isShared ? SharedSetup.inAppGroup() : nil,
                                     setupPreference: (defaults, BrowserStorage.setupPreferenceKey))
        } catch {
            return CommonEnvironment(database: try! AppDatabase.inMemory(), secrets: secrets, mediaDirectory: media,
                                     dictionaryDirectory: dictionaries,
                                     startupError: "Couldn't open the database: \(error.localizedDescription)")
        }
    }
}
