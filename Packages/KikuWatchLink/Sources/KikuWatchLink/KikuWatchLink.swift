import Foundation

/// What's playing in Kiku on the iPhone. The phone sends it with `updateApplicationContext` on
/// every change (play, pause, seek, speed, chapter, another episode), never once a second: the
/// watch works out the position from `sampledAt`.
public struct WatchNowPlaying: Codable, Equatable, Sendable {
    public var itemId: String
    /// Empty for a book.
    public var episodeId: String
    /// The episode's or book's title.
    public var title: String
    /// The show, or the book's author.
    public var subtitle: String
    public var chapter: String?
    /// Seconds, at `sampledAt`.
    public var position: Double
    public var duration: Double
    public var rate: Double
    public var isPlaying: Bool
    public var sampledAt: Date
    public var skipBackward: Double
    public var skipForward: Double
    /// A small JPEG of the cover (100 px at most).
    public var artwork: Data?
    /// Live Text's transcript for this episode (`WatchTranscript.id`): set with Live Text on and
    /// a transcript on the phone. The watch asks for it if it doesn't have it.
    public var transcript: String?

    public init(itemId: String, episodeId: String, title: String, subtitle: String, chapter: String? = nil,
                position: Double, duration: Double, rate: Double, isPlaying: Bool, sampledAt: Date,
                skipBackward: Double = 15, skipForward: Double = 30, artwork: Data? = nil, transcript: String? = nil) {
        self.itemId = itemId
        self.episodeId = episodeId
        self.title = title
        self.subtitle = subtitle
        self.chapter = chapter
        self.position = position
        self.duration = duration
        self.rate = rate
        self.isPlaying = isPlaying
        self.sampledAt = sampledAt
        self.skipBackward = skipBackward
        self.skipForward = skipForward
        self.artwork = artwork
        self.transcript = transcript
    }

    /// "<item>/<episode>", or a book's "<item>" (Kiku's progress key).
    public var key: String { episodeId.isEmpty ? itemId : "\(itemId)/\(episodeId)" }

    /// The position at `date`: moving at `rate` while playing, within the episode.
    public func position(at date: Date) -> Double {
        guard isPlaying else { return position }
        let moved = position + max(date.timeIntervalSince(sampledAt), 0) * rate
        return duration > 0 ? min(moved, duration) : moved
    }

    /// How far along at `date`, 0…1.
    public func fraction(at date: Date) -> Double {
        duration > 0 ? min(max(position(at: date) / duration, 0), 1) : 0
    }

    /// Whether `newer` tells the watch nothing new: the same episode, chapter, speed and play
    /// state, at the position this one predicts (within `tolerance` seconds). Then it isn't sent.
    public func predicts(_ newer: WatchNowPlaying, tolerance: Double = 1.5) -> Bool {
        key == newer.key && title == newer.title && chapter == newer.chapter && rate == newer.rate
            && isPlaying == newer.isPlaying && duration == newer.duration
            && skipBackward == newer.skipBackward && skipForward == newer.skipForward && transcript == newer.transcript
            && abs(position(at: newer.sampledAt) - newer.position) <= tolerance
    }
}

/// The phone's whole state for the watch: nil when nothing is loaded in Kiku.
public struct WatchState: Codable, Equatable, Sendable {
    public var nowPlaying: WatchNowPlaying?
    /// Live Text on Apple Watch is on in Kiku's settings.
    public var liveText: Bool

    public init(nowPlaying: WatchNowPlaying?, liveText: Bool = false) {
        self.nowPlaying = nowPlaying
        self.liveText = liveText
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        nowPlaying = try container.decodeIfPresent(WatchNowPlaying.self, forKey: .nowPlaying)
        // A state saved before Live Text.
        liveText = try container.decodeIfPresent(Bool.self, forKey: .liveText) ?? false
    }
}

/// A mark made on the watch while the phone was out of reach, sent later with `transferUserInfo`.
/// It carries the episode and the position the watch worked out, so it marks the right moment
/// even if the phone has moved on.
public struct WatchQueuedMark: Codable, Equatable, Sendable {
    public var itemId: String
    public var episodeId: String
    public var title: String
    public var subtitle: String
    public var position: Double
    public var markedAt: Date
    /// A line chosen in Live Text: `position` is its start, and the mark is about that line.
    public var wholeLine: Bool?

    public init(itemId: String, episodeId: String, title: String, subtitle: String, position: Double, markedAt: Date,
                wholeLine: Bool? = nil) {
        self.itemId = itemId
        self.episodeId = episodeId
        self.title = title
        self.subtitle = subtitle
        self.position = position
        self.markedAt = markedAt
        self.wholeLine = wholeLine
    }

    public init(_ playing: WatchNowPlaying, at date: Date) {
        self.init(itemId: playing.itemId, episodeId: playing.episodeId, title: playing.title,
                  subtitle: playing.subtitle, position: playing.position(at: date), markedAt: date)
    }

    /// Live Text's Mark Line: at the line's start.
    public init(line: WatchTranscript.Line, of playing: WatchNowPlaying, at date: Date) {
        self.init(itemId: playing.itemId, episodeId: playing.episodeId, title: playing.title,
                  subtitle: playing.subtitle, position: line.start, markedAt: date, wholeLine: true)
    }
}

/// A button on the watch, sent with `sendMessage`. Live Text's name a line by the episode key
/// and its position, so a line from an episode that's no longer playing isn't confused with one.
public enum WatchCommand: Codable, Equatable, Sendable {
    case togglePlay, skipBackward, skipForward, mark
    case markLine(key: String, line: Int)
    /// Plays the line's clip on the phone.
    case replayLine(key: String, line: Int)
    /// Looks up the word at a character of the line, on the phone (which pauses until `endLookup`).
    case lookUp(key: String, line: Int, character: Int)
    /// The lookup closed: the phone plays again if the lookup paused it.
    case endLookup
    /// Adds the card for that lookup, on the phone (through its outbox).
    case addCard(key: String, line: Int, character: Int)
    /// Live Text's transcript (by `WatchTranscript.id`), the lines from `from` on.
    case transcriptPart(id: String, from: Int)
}

/// The phone's answer to a command.
public struct WatchReply: Codable, Equatable, Sendable {
    /// What to show: "Marked 0:52", "Nothing is playing".
    public var message: String?
    /// For a mark: where it was made, in seconds.
    public var markedAt: Double?
    /// For a lookup: the word.
    public var lookup: WatchLookup?
    /// For a card: it was queued (`message` has the word and the deck).
    public var cardAdded: Bool?
    /// For `transcriptPart`: the lines.
    public var transcriptPart: WatchTranscriptPart?
    /// The state after the command, so the watch needn't wait for the next context.
    public var state: WatchState

    public init(message: String? = nil, markedAt: Double? = nil, lookup: WatchLookup? = nil, cardAdded: Bool? = nil,
                transcriptPart: WatchTranscriptPart? = nil, state: WatchState) {
        self.message = message
        self.markedAt = markedAt
        self.lookup = lookup
        self.cardAdded = cardAdded
        self.transcriptPart = transcriptPart
        self.state = state
    }
}

/// The dictionaries WatchConnectivity carries: one JSON value under one key each.
public enum WatchMessages {
    static let state = "state"
    static let command = "command"
    static let reply = "reply"
    static let queuedMark = "queuedMark"

    public static func context(_ state: WatchState) -> [String: Any] { encode(state, as: Self.state) }
    public static func state(from context: [String: Any]) -> WatchState? { decode(context, Self.state) }

    public static func message(_ command: WatchCommand) -> [String: Any] { encode(command, as: Self.command) }
    public static func command(from message: [String: Any]) -> WatchCommand? { decode(message, Self.command) }

    public static func message(_ reply: WatchReply) -> [String: Any] { encode(reply, as: Self.reply) }
    public static func reply(from message: [String: Any]) -> WatchReply? { decode(message, Self.reply) }

    public static func userInfo(_ mark: WatchQueuedMark) -> [String: Any] { encode(mark, as: queuedMark) }
    public static func queuedMark(from userInfo: [String: Any]) -> WatchQueuedMark? { decode(userInfo, queuedMark) }

    private static func encode(_ value: some Encodable, as key: String) -> [String: Any] {
        guard let data = try? JSONEncoder().encode(value) else { return [:] }
        return [key: data]
    }

    private static func decode<Value: Decodable>(_ dictionary: [String: Any], _ key: String) -> Value? {
        guard let data = dictionary[key] as? Data else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
    }
}

public extension Double {
    /// "0:52", "13:21", "1:02:05".
    var watchClock: String {
        let total = Int(max(self, 0).rounded(.down))
        let (hours, minutes, seconds) = (total / 3600, total % 3600 / 60, total % 60)
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, seconds) : String(format: "%d:%02d", minutes, seconds)
    }
}

/// The watch app's last state, kept where its complication (a widget extension) can read it: the
/// App Group when there is one, else the app's own defaults (then the complication shows only
/// the glyph).
public enum WatchStateStore {
    public static let appGroup = "group.com.amatsubame"
    static let key = "kiku.watch.state"

    private static var defaults: UserDefaults { UserDefaults(suiteName: appGroup) ?? .standard }

    public static func save(_ state: WatchState?) {
        guard let state, let data = try? JSONEncoder().encode(state) else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(data, forKey: key)
    }

    public static func load() -> WatchState? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(WatchState.self, from: $0) }
    }
}
