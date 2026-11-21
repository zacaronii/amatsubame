import Foundation

// MARK: What's on the watch (docs/KIKU_PLAN.md milestone 2)
// The phone keeps the list of what should be on the watch and sends it whole in its
// application context; the watch downloads what's missing straight from Audiobookshelf and
// removes what's gone from the list. The watch answers with its own context: each item's state
// and its free space.

/// An episode or a book sent to the watch: one audio file on Audiobookshelf.
public struct WatchItem: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var itemId: String
    /// Empty for a book.
    public var episodeId: String
    /// The audio file's inode: `api/items/<itemId>/file/<ino>`.
    public var ino: String
    /// "mp3", "m4a"…: the watch's file name, so AVPlayer knows the format.
    public var fileExtension: String
    public var title: String
    /// The show, or the book's author.
    public var subtitle: String
    public var duration: Double
    /// Bytes, when Audiobookshelf says.
    public var size: Int64?
    public var chapters: [Chapter]
    public var addedAt: Date
    /// Send Now: the phone sends its own download with `transferFile` (for a server the watch
    /// can't reach), so the watch doesn't download it itself.
    public var fromPhone: Bool
    /// Why it's on the watch: nil when you sent it, otherwise the rule that added it (milestone 4).
    public var reason: Reason?
    /// Its transcript's id (`WatchTranscript.id`) when the phone has one and Live Text is on:
    /// the watch fetches it while the phone is near, for Live Text without it (milestone 5).
    public var transcript: String?

    public enum Reason: String, Codable, Sendable {
        /// Sync to Watch Once Started.
        case started
        /// Watch download ahead.
        case ahead
    }

    public struct Chapter: Codable, Equatable, Hashable, Sendable {
        public var title: String
        public var start: Double

        public init(title: String, start: Double) {
            self.title = title
            self.start = start
        }
    }

    public init(itemId: String, episodeId: String, ino: String, fileExtension: String, title: String, subtitle: String,
                duration: Double, size: Int64? = nil, chapters: [Chapter] = [], addedAt: Date, fromPhone: Bool = false, reason: Reason? = nil) {
        self.itemId = itemId
        self.episodeId = episodeId
        self.ino = ino
        self.fileExtension = fileExtension
        self.title = title
        self.subtitle = subtitle
        self.duration = duration
        self.size = size
        self.chapters = chapters
        self.addedAt = addedAt
        self.fromPhone = fromPhone
        self.reason = reason
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        itemId = try container.decode(String.self, forKey: .itemId)
        episodeId = try container.decode(String.self, forKey: .episodeId)
        ino = try container.decode(String.self, forKey: .ino)
        fileExtension = try container.decode(String.self, forKey: .fileExtension)
        title = try container.decode(String.self, forKey: .title)
        subtitle = try container.decode(String.self, forKey: .subtitle)
        duration = try container.decode(Double.self, forKey: .duration)
        size = try container.decodeIfPresent(Int64.self, forKey: .size)
        chapters = try container.decode([Chapter].self, forKey: .chapters)
        addedAt = try container.decode(Date.self, forKey: .addedAt)
        fromPhone = try container.decodeIfPresent(Bool.self, forKey: .fromPhone) ?? false
        reason = try container.decodeIfPresent(Reason.self, forKey: .reason)
        transcript = try container.decodeIfPresent(String.self, forKey: .transcript)
    }

    /// Kiku's progress key, as `WatchNowPlaying.key`.
    public var key: String { episodeId.isEmpty ? itemId : "\(itemId)/\(episodeId)" }
    public var id: String { key }
    /// The file's name on the watch (a key's "/" can't be in one).
    public var fileName: String { "\(key.replacingOccurrences(of: "/", with: "-")).\(fileExtension)" }
    /// The download's path under the server's URL.
    public var downloadPath: String { "api/items/\(itemId)/file/\(ino)" }
}

/// How the watch reaches Audiobookshelf: the server and a bearer token from the phone.
public struct WatchAccess: Codable, Equatable, Sendable {
    public var server: URL
    public var token: String
    /// An API key made for the watch, which doesn't run out. Otherwise the phone's access token
    /// (an hour): the watch asks the phone for a fresh one before downloading.
    public var isAPIKey: Bool

    public init(server: URL, token: String, isAPIKey: Bool) {
        self.server = server
        self.token = token
        self.isAPIKey = isAPIKey
    }

    /// A signed request for an item's audio.
    public func request(for item: WatchItem) -> URLRequest {
        var request = URLRequest(url: server.appending(path: item.downloadPath))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// When a JWT access token runs out (nil for an API key, or one that doesn't say).
    public var expiry: Date? {
        guard !isAPIKey else { return nil }
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = json["exp"] as? Double else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    /// A signed request for an item's cover, small enough for Now Playing.
    public func coverRequest(itemId: String) -> URLRequest {
        var components = URLComponents(url: server.appending(path: "api/items/\(itemId)/cover"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "width", value: "200"), URLQueryItem(name: "format", value: "jpeg")]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// Good for at least `margin` more (a download can start a while after it's queued).
    public func lasts(_ margin: TimeInterval = 10 * 60, at date: Date = .now) -> Bool {
        guard let expiry else { return true }
        return expiry > date.addingTimeInterval(margin)
    }
}

/// A place in an item, and when it was there: the newer of the phone's and the watch's wins.
public struct WatchPlace: Codable, Equatable, Sendable {
    public var position: Double
    public var updatedAt: Date

    public init(position: Double, updatedAt: Date) {
        self.position = position
        self.updatedAt = updatedAt
    }
}

/// The phone's list for the watch, and how to download it. No access: signed out on the phone,
/// so the watch forgets its token (its downloads stay until removed).
public struct WatchLibrary: Codable, Equatable, Sendable {
    public var items: [WatchItem]
    public var access: WatchAccess?
    /// Where the phone (or Audiobookshelf) last was in each item, by key: the watch starts there
    /// unless it played the item more recently itself.
    public var places: [String: WatchPlace]
    /// The watch's listening the phone has applied: each id with the `endedAt` of the version it
    /// has. The watch drops a stretch once this covers it (the latest few hundred).
    public var acknowledged: [String: Date]

    public init(items: [WatchItem] = [], access: WatchAccess? = nil, places: [String: WatchPlace] = [:],
                acknowledged: [String: Date] = [:]) {
        self.items = items
        self.access = access
        self.places = places
        self.acknowledged = acknowledged
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decode([WatchItem].self, forKey: .items)
        access = try container.decodeIfPresent(WatchAccess.self, forKey: .access)
        places = try container.decodeIfPresent([String: WatchPlace].self, forKey: .places) ?? [:]
        acknowledged = try container.decodeIfPresent([String: Date].self, forKey: .acknowledged) ?? [:]
    }
}

/// Where one item is on the watch.
public struct WatchItemStatus: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        /// Queued: watchOS starts it when it chooses (most readily on the charger).
        case waiting
        case downloading
        case ready
        case failed
    }

    public var state: State
    public var bytesDone: Int64
    public var bytesTotal: Int64?
    /// Why it failed, or what it's waiting for ("Waiting for your iPhone").
    public var message: String?
    /// What Audiobookshelf answered when the download failed: a 404 has the phone look the
    /// item up again (its file may have changed since).
    public var httpStatus: Int?

    public init(state: State, bytesDone: Int64 = 0, bytesTotal: Int64? = nil, message: String? = nil, httpStatus: Int? = nil) {
        self.state = state
        self.bytesDone = bytesDone
        self.bytesTotal = bytesTotal
        self.message = message
        self.httpStatus = httpStatus
    }

    public var fraction: Double? {
        guard let bytesTotal, bytesTotal > 0 else { return nil }
        return min(Double(bytesDone) / Double(bytesTotal), 1)
    }

    /// "Waiting", "40%", "Ready · 52 MB", "Failed: …".
    public var text: String {
        switch state {
        case .waiting: message ?? "Waiting"
        case .downloading: fraction.map { "\(Int(($0 * 100).rounded(.down)))%" } ?? "Downloading"
        case .ready: bytesDone > 0 ? "Ready · \(Self.size(bytesDone))" : "Ready"
        case .failed: message.map { "Failed: \($0)" } ?? "Failed"
        }
    }

    /// "52 MB", "1.2 GB".
    public static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// The watch's answer to the library: each item's state by key, and its free space.
public struct WatchInventory: Codable, Equatable, Sendable {
    public var items: [String: WatchItemStatus]
    public var freeBytes: Int64?
    public var updatedAt: Date

    public init(items: [String: WatchItemStatus] = [:], freeBytes: Int64? = nil, updatedAt: Date) {
        self.items = items
        self.freeBytes = freeBytes
        self.updatedAt = updatedAt
    }

    /// The same states and roughly the same free space: not worth sending again. Progress is
    /// sent in steps of 10%, so the phone's list moves without a message per chunk.
    public func matches(_ other: WatchInventory) -> Bool {
        guard items.keys == other.items.keys else { return false }
        for (key, status) in items {
            guard let theirs = other.items[key], theirs.state == status.state, theirs.message == status.message,
                  Self.step(status) == Self.step(theirs) else { return false }
        }
        let free = (freeBytes ?? 0) / 50_000_000, theirFree = (other.freeBytes ?? 0) / 50_000_000
        return free == theirFree
    }

    private static func step(_ status: WatchItemStatus) -> Int {
        Int(((status.fraction ?? 0) * 10).rounded(.down))
    }
}

// MARK: Listening back to the phone (docs/KIKU_PLAN.md milestone 3)

/// One stretch of listening on the watch to one item: like a Stats session, a pause longer than
/// `WatchListening.gap` or another item starts the next. It's kept on the watch, and sent again
/// as it grows, until the phone acknowledges the version it has (`WatchLibrary.acknowledged`).
/// Its id is also the Audiobookshelf session's.
public struct WatchListening: Codable, Equatable, Sendable, Identifiable {
    /// Five minutes, as the phone's Stats count a session.
    public static let gap: TimeInterval = 5 * 60

    public var id: String
    public var itemId: String
    public var episodeId: String
    public var title: String
    public var duration: Double
    public var startPosition: Double
    public var endPosition: Double
    /// Real playback, at any speed (not seeks).
    public var seconds: Double
    public var rate: Double
    public var startedAt: Date
    public var endedAt: Date
    /// It played to the end.
    public var finished: Bool

    public init(id: String = UUID().uuidString.lowercased(), item: WatchItem, position: Double, rate: Double, at date: Date) {
        self.id = id
        itemId = item.itemId
        episodeId = item.episodeId
        title = item.title
        duration = item.duration
        startPosition = position
        endPosition = position
        seconds = 0
        self.rate = rate
        startedAt = date
        endedAt = date
        finished = false
    }

    public var key: String { episodeId.isEmpty ? itemId : "\(itemId)/\(episodeId)" }

    /// Whether more listening to `key` at `date` belongs to this stretch.
    public func continues(_ key: String, at date: Date) -> Bool {
        self.key == key && date.timeIntervalSince(endedAt) <= Self.gap
    }

    /// `seconds` more of playback, now at `position`.
    public mutating func add(_ seconds: Double, at position: Double, rate: Double, on date: Date, finished: Bool = false) {
        self.seconds += max(seconds, 0)
        endPosition = position
        self.rate = rate
        endedAt = max(endedAt, date)
        if finished { self.finished = true }
    }
}

public extension WatchMessages {
    /// The watch's unacknowledged listening, sent with `transferUserInfo` (and `sendMessage`
    /// when the phone is near, for Sync Now).
    static func userInfo(listening: [WatchListening]) -> [String: Any] { encode(listening, as: "watchListening") }
    static func listening(from userInfo: [String: Any]) -> [WatchListening]? { decode(userInfo, "watchListening") }

    /// The phone's answer to listening sent with `sendMessage`: what it has applied.
    static func message(acknowledged: [String: Date]) -> [String: Any] { encode(acknowledged, as: "acknowledged") }
    static func acknowledged(from message: [String: Any]) -> [String: Date]? { decode(message, "acknowledged") }

    /// Send Now: the metadata of the phone's `transferFile`, naming the item it is.
    static func metadata(fileFor key: String) -> [String: Any] { ["watchFile": key] }
    static func fileKey(from metadata: [String: Any]?) -> String? { metadata?["watchFile"] as? String }
}
