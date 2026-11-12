import Core
import Foundation

/// For setup's UI tests (DEBUG only): `UITEST_SETUP_DATA=<name>` keeps everything the app
/// stores in a separate set named `<name>` (its folder, Keychain items, setup state and the
/// shared setup), so each test starts as a first launch, a relaunch keeps its progress, and
/// two apps given the same name share a setup with each other only.
public enum SetupTestData {
    public static var name: String? {
        #if DEBUG
        ProcessInfo.processInfo.environment["UITEST_SETUP_DATA"].flatMap { $0.isEmpty ? nil : $0 }
        #else
        nil
        #endif
    }

    /// The app's Application Support folder, or the test set's.
    public static func support(_ folder: URL = .applicationSupportDirectory) -> URL {
        name.map { folder.appending(path: "UITestSetup/\($0)", directoryHint: .isDirectory) } ?? folder
    }

    /// The app's own Keychain items.
    public static func secrets() -> KeychainSecretStore {
        guard let name else { return KeychainSecretStore() }
        return KeychainSecretStore(service: "\(Bundle.main.bundleIdentifier ?? "app").uitest.\(name)")
    }

    /// The app's own Keychain items, emptied when `database` (the database folder) doesn't
    /// exist yet: iOS keeps an app's Keychain items after it's deleted, so a fresh install
    /// would otherwise show the old keys and passwords with no server. Call before opening the database.
    public static func secrets(database: URL) -> KeychainSecretStore {
        let secrets = secrets()
        if !FileManager.default.fileExists(atPath: database.path(percentEncoded: false)) {
            try? secrets.removeAll()
        }
        return secrets
    }

    /// The shared setup in the App Group, or the test set's own part of it.
    public static func sharedSetup() -> SharedSetup? {
        guard let shared = SharedSetup.inAppGroup() else { return nil }
        guard let name else { return shared }
        let root = shared.root.appending(path: "UITest/\(name)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return SharedSetup(root: root)
    }

    static var sharedKeychainService: String {
        name.map { "\(SharedSetup.keychainService).uitest.\($0)" } ?? SharedSetup.keychainService
    }

    /// Where per-app choices (sharing, setup progress) are kept.
    public static var defaults: UserDefaults {
        name.flatMap { UserDefaults(suiteName: "uitest.\($0).\(Bundle.main.bundleIdentifier ?? "app")") } ?? .standard
    }
}
