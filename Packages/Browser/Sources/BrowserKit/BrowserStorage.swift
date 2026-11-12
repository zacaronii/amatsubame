import Core
import Foundation

/// Where the Browser app and its Safari extension keep their data. With the App Group
/// (paid developer membership) both use the shared folder; until then each process uses
/// its own container, so the extension keeps its own dictionaries and settings.
public enum BrowserStorage {
    public static let groupIdentifier = SharedSetup.groupIdentifier
    /// The Keychain service of Hiku's own secrets (the app and the extension have
    /// different bundle ids, so it's named explicitly).
    public static let keychainService = "com.amatsubame.hiku"
    /// Where Hiku keeps its "share setup" choice in the App Group's defaults, so
    /// the extension follows it.
    public static let setupPreferenceKey = "setupSharing.lookup"

    public struct Location: Equatable, Sendable {
        /// Holds `Database/`, `Dictionaries/` and `OutboxMedia/`.
        public var root: URL
        /// In the App Group folder, so the app and the extension see the same data.
        public var isShared: Bool

        public init(root: URL, isShared: Bool) {
            self.root = root
            self.isShared = isShared
        }
    }

    /// The App Group folder when this process is entitled to it, else its own Application Support.
    public static func location(
        groupIdentifier: String = groupIdentifier,
        containerURL: (String) -> URL? = { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) },
        ownSupport: URL = .applicationSupportDirectory
    ) -> Location {
        // Without the entitlement iOS returns nil; macOS may return a folder it then won't let us write.
        if let group = containerURL(groupIdentifier) {
            // The folder keeps the app's old name (Japanese Lookup, now Hiku): it holds the data.
            let root = group.appending(path: "Library/Application Support/Japanese Lookup", directoryHint: .isDirectory)
            if (try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)) != nil {
                return Location(root: root, isShared: true)
            }
        }
        return Location(root: ownSupport, isShared: false)
    }
}
