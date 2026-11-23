import Foundation

/// What Kiku's widgets show: the episode or book playing (or last played) and the next two
/// (Up Next, else Continue Listening). Kiku writes it to the App Group when playback changes;
/// the widgets only read it, so they never call a server and no sign-in leaves the app.
public struct WidgetSnapshot: Codable, Equatable, Sendable {
    public struct Item: Codable, Equatable, Sendable, Identifiable {
        public var key: String
        public var itemId: String
        public var title: String
        public var show: String
        /// Seconds left, and how far it's been listened (0…1).
        public var timeLeft: Double
        public var fraction: Double

        public init(key: String, itemId: String, title: String, show: String, timeLeft: Double, fraction: Double) {
            self.key = key
            self.itemId = itemId
            self.title = title
            self.show = show
            self.timeLeft = timeLeft
            self.fraction = fraction
        }

        public var id: String { key }
    }

    public var current: Item?
    public var isPlaying: Bool
    /// What the list under it is: "Up Next" or "Continue Listening".
    public var nextTitle: String
    public var next: [Item]
    public var updatedAt: Date

    public init(current: Item?, isPlaying: Bool, nextTitle: String, next: [Item], updatedAt: Date) {
        self.current = current
        self.isPlaying = isPlaying
        self.nextTitle = nextTitle
        self.next = next
        self.updatedAt = updatedAt
    }

    public static let empty = WidgetSnapshot(current: nil, isPlaying: false, nextTitle: "", next: [], updatedAt: .distantPast)
}

/// The snapshot and its covers in the App Group (`Widgets/`). Nil without the App Group (a
/// build without it has no widgets).
public struct WidgetSnapshotStore: Sendable {
    public static let groupIdentifier = "group.com.amatsubame"
    public let folder: URL

    public init(folder: URL) {
        self.folder = folder
    }

    public static func inAppGroup() -> WidgetSnapshotStore? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier)
            .map { WidgetSnapshotStore(folder: $0.appending(path: "Widgets")) }
    }

    var snapshotURL: URL { folder.appending(path: "snapshot.json") }

    public func coverURL(itemId: String) -> URL {
        let safe = itemId.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return folder.appending(path: "covers").appending(path: "\(safe).jpg")
    }

    public func read() -> WidgetSnapshot {
        (try? JSONDecoder().decode(WidgetSnapshot.self, from: Data(contentsOf: snapshotURL))) ?? .empty
    }

    /// Writes it when it changed (true then: the widgets should reload).
    @discardableResult
    public func write(_ snapshot: WidgetSnapshot) throws -> Bool {
        var compared = read()
        compared.updatedAt = snapshot.updatedAt
        guard compared != snapshot else { return false }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot).write(to: snapshotURL, options: .atomic)
        return true
    }

    public func hasCover(itemId: String) -> Bool {
        FileManager.default.fileExists(atPath: coverURL(itemId: itemId).path(percentEncoded: false))
    }

    public func saveCover(_ jpeg: Data, itemId: String) throws {
        let url = coverURL(itemId: itemId)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try jpeg.write(to: url, options: .atomic)
    }

    /// Keeps only the covers the snapshot shows.
    public func pruneCovers(keeping itemIds: Set<String>) {
        let folder = folder.appending(path: "covers")
        let keep = Set(itemIds.map { coverURL(itemId: $0).lastPathComponent })
        for file in (try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? [] where !keep.contains(file) {
            try? FileManager.default.removeItem(at: folder.appending(path: file))
        }
    }
}
