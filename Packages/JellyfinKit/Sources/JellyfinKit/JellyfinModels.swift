import Foundation

// Shapes verified against Jellyfin 12.3.0 (2026-10-31, fixtures in the tests). Jellyfin
// uses PascalCase keys; `JellyfinClient.decoder` maps them to these camelCase names.

/// Jellyfin positions and durations are in ticks of 100 ns.
public enum JellyfinTicks {
    public static let perSecond: Int64 = 10_000_000

    public static func seconds(_ ticks: Int64) -> Double { Double(ticks) / Double(perSecond) }
    public static func ticks(_ seconds: Double) -> Int64 { Int64((max(seconds, 0) * Double(perSecond)).rounded()) }
}

public struct JellyfinItemsPage: Decodable, Sendable {
    public var items: [JellyfinItem]
    public var totalRecordCount: Int?
}

/// A library, series, season, episode or movie.
public struct JellyfinItem: Decodable, Identifiable, Equatable, Hashable, Sendable {
    public var id: String
    public var name: String
    /// "CollectionFolder", "Series", "Season", "Episode", "Movie", …
    public var type: String
    /// For libraries: "tvshows", "movies", …
    public var collectionType: String?
    public var overview: String?
    public var productionYear: Int?
    /// Episode number, or season number for seasons.
    public var indexNumber: Int?
    /// Season number of an episode.
    public var parentIndexNumber: Int?
    public var seriesId: String?
    public var seriesName: String?
    public var seasonId: String?
    public var seasonName: String?
    public var runTimeTicks: Int64?
    public var childCount: Int?
    /// Episodes in a series (with `fields=RecursiveItemCount`, or on the series item).
    public var recursiveItemCount: Int?
    public var imageTags: [String: String]?
    public var seriesPrimaryImageTag: String?
    public var userData: JellyfinUserData?
    /// Present when requested with `fields=MediaStreams` (episodes lists) or on `item(id:)`.
    public var mediaStreams: [JellyfinMediaStream]?
    public var mediaSources: [JellyfinMediaSource]?
    /// Other databases' ids ("AniDB", "Tmdb", "Shoko Series"…).
    public var providerIds: [String: String]?
    /// Scrub thumbnails the server made, by media source id, then by thumbnail width.
    public var trickplay: [String: [String: JellyfinTrickplayInfo]]?

    public init(id: String, name: String, type: String) {
        self.id = id
        self.name = name
        self.type = type
    }

    public var isEpisode: Bool { type == "Episode" }

    /// "S1E5" for episodes; nil otherwise.
    public var episodeLabel: String? {
        guard isEpisode, let episode = indexNumber else { return nil }
        return parentIndexNumber.map { "S\($0)E\(episode)" } ?? "E\(episode)"
    }

    public var duration: Double? { runTimeTicks.map(JellyfinTicks.seconds) }

    /// Where to resume, in seconds; nil when unwatched or finished.
    public var resumePosition: Double? {
        guard let ticks = userData?.playbackPositionTicks, ticks > 0, userData?.played != true else { return nil }
        return JellyfinTicks.seconds(ticks)
    }

    /// The Japanese subtitle track the app would use; nil when there's none it can read.
    /// Needs `mediaStreams` (nil when they weren't requested).
    public var japaneseSubtitle: JellyfinMediaStream? {
        JellyfinSubtitlePicker.japanese(in: mediaStreams ?? [])
    }

    /// Whether an audio track is tagged Japanese (untagged audio doesn't count). Needs `mediaStreams`.
    public var hasJapaneseAudio: Bool {
        (mediaStreams ?? []).contains { $0.isAudio && $0.isJapanese }
    }
}

public struct JellyfinUserData: Decodable, Equatable, Hashable, Sendable {
    public var playbackPositionTicks: Int64?
    public var playCount: Int?
    public var played: Bool?
    public var playedPercentage: Double?
    public var unplayedItemCount: Int?
    public var lastPlayedDate: Date?
}

public struct JellyfinMediaStream: Decodable, Equatable, Hashable, Sendable {
    /// The stream's index in its media source (used in subtitle URLs and reports).
    public var index: Int
    /// "Video", "Audio", "Subtitle", …
    public var type: String
    public var language: String?
    public var codec: String?
    public var title: String?
    public var displayTitle: String?
    public var isExternal: Bool?
    public var isTextSubtitleStream: Bool?
    public var isForced: Bool?
    public var isDefault: Bool?
    /// The file on the server, for separate (external) subtitle files.
    public var path: String?

    public init(index: Int, type: String, language: String? = nil, codec: String? = nil, title: String? = nil,
                isExternal: Bool = false, isTextSubtitleStream: Bool = false, isForced: Bool = false) {
        self.index = index
        self.type = type
        self.language = language
        self.codec = codec
        self.title = title
        self.isExternal = isExternal
        self.isTextSubtitleStream = isTextSubtitleStream
        self.isForced = isForced
    }

    public var isSubtitle: Bool { type == "Subtitle" }
    public var isAudio: Bool { type == "Audio" }
    public var isJapanese: Bool { ["jpn", "ja", "jp"].contains(language?.lowercased() ?? "") }
    public var isEnglish: Bool { ["eng", "en"].contains(language?.lowercased() ?? "") }
}

public struct JellyfinMediaSource: Decodable, Equatable, Hashable, Sendable {
    public var id: String
    public var container: String?
    public var size: Int64?
    public var bitrate: Int?
    public var runTimeTicks: Int64?
    public var supportsDirectPlay: Bool?
    public var defaultAudioStreamIndex: Int?
    public var mediaStreams: [JellyfinMediaStream]?
}

public struct JellyfinPlaybackInfo: Decodable, Sendable {
    public var mediaSources: [JellyfinMediaSource]
    public var playSessionId: String?
}

/// Chooses which of an item's tracks to use.
public enum JellyfinSubtitlePicker {
    /// The best Japanese text subtitle: external SRT, then embedded SRT, then ASS/SSA,
    /// skipping image formats (PGS, VobSub); a full track beats "Forced" or "Signs" ones.
    public static func japanese(in streams: [JellyfinMediaStream]) -> JellyfinMediaStream? {
        best(streams.filter(\.isJapanese))
    }

    /// All Japanese text subtitles, best first (`japanese(in:)` is the first): the J key
    /// cycles through them.
    public static func japaneseTracks(in streams: [JellyfinMediaStream]) -> [JellyfinMediaStream] {
        streams.filter { $0.isJapanese && $0.isSubtitle && isText($0) }
            .enumerated()
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map(\.element)
    }

    /// The best English text subtitle (for mpv's optional secondary line).
    public static func english(in streams: [JellyfinMediaStream]) -> JellyfinMediaStream? {
        best(streams.filter(\.isEnglish))
    }

    /// Text tracks to sync an outside subtitle file to, best first: tracks inside the video
    /// (always timed to it; external files may come from another release), full ones before
    /// signs and songs, English first.
    public static func syncReferences(in streams: [JellyfinMediaStream]) -> [JellyfinMediaStream] {
        streams
            .filter { $0.isSubtitle && isText($0) && !isPartial($0) }
            .enumerated()
            .sorted { a, b in
                let ka = (a.element.isExternal == true ? 1 : 0, a.element.isEnglish ? 0 : 1, a.offset)
                let kb = (b.element.isExternal == true ? 1 : 0, b.element.isEnglish ? 0 : 1, b.offset)
                return ka < kb
            }
            .map(\.element)
    }

    static func isPartial(_ stream: JellyfinMediaStream) -> Bool {
        let title = (stream.title ?? "").lowercased()
        return stream.isForced == true || title.contains("sign") || title.contains("song") || title.contains("forced")
    }

    private static func best(_ streams: [JellyfinMediaStream]) -> JellyfinMediaStream? {
        streams
            .filter { $0.isSubtitle && isText($0) }
            .min { rank($0) < rank($1) }
    }

    static func isText(_ stream: JellyfinMediaStream) -> Bool {
        if let isText = stream.isTextSubtitleStream { return isText }
        return ["subrip", "srt", "ass", "ssa", "webvtt", "vtt", "mov_text"].contains(stream.codec?.lowercased() ?? "")
    }

    /// Lower is better; ties keep the stream order (`min` returns the first).
    private static func rank(_ stream: JellyfinMediaStream) -> Int {
        let codec = stream.codec?.lowercased() ?? ""
        let isSRT = codec == "subrip" || codec == "srt"
        var rank = switch (isSRT, stream.isExternal == true) {
        case (true, true): 0
        case (true, false): 1
        default: 2
        }
        if isPartial(stream) { rank += 10 }
        return rank
    }
}

/// One playback report, queued in the outbox (kind `jellyfinProgress`, coalesced per item).
public struct JellyfinProgressPayload: Codable, Equatable, Sendable {
    public enum Event: String, Codable, Sendable {
        /// Playback began (`/Sessions/Playing`).
        case started
        /// A time update (`/Sessions/Playing/Progress`, EventName TimeUpdate): regular, or after a seek.
        case progress
        /// Progress reports with EventName Pause / Unpause.
        case paused, unpaused
        case stopped

        /// Jellyfin's `ProgressEvent` for progress reports.
        var progressEventName: String? {
            switch self {
            case .progress: "TimeUpdate"
            case .paused: "Pause"
            case .unpaused: "Unpause"
            case .started, .stopped: nil
            }
        }
    }

    public var itemId: String
    public var mediaSourceId: String
    public var playSessionId: String?
    public var positionTicks: Int64
    public var isPaused: Bool
    public var event: Event
    /// Jellyfin's stream indexes of the audio and subtitles playing (nil when unknown or none).
    public var audioStreamIndex: Int?
    public var subtitleStreamIndex: Int?
    /// When the position was taken (a queued report can be sent much later; nil in reports
    /// queued by older versions).
    public var reportedAt: Date?

    public init(itemId: String, mediaSourceId: String, playSessionId: String?, positionTicks: Int64,
                isPaused: Bool = false, event: Event, audioStreamIndex: Int? = nil, subtitleStreamIndex: Int? = nil,
                reportedAt: Date? = nil) {
        self.itemId = itemId
        self.mediaSourceId = mediaSourceId
        self.playSessionId = playSessionId
        self.positionTicks = positionTicks
        self.isPaused = isPaused
        self.event = event
        self.audioStreamIndex = audioStreamIndex
        self.subtitleStreamIndex = subtitleStreamIndex
        self.reportedAt = reportedAt
    }

    /// Only plain time updates replace each other while waiting to send (e.g. offline):
    /// starts, pauses and stops must all reach the server, in order.
    public var coalesceKey: String? {
        event == .progress ? "jellyfin.item.\(itemId).progress" : nil
    }
}

extension JellyfinMediaStream {
    /// This stream's index in the file as FFmpeg numbers it (for `MediaClipper`), or nil
    /// for external files. Jellyfin numbers external subtitles first, then the file's own
    /// streams in order, so the file's streams are offset by the external count.
    public func ffmpegIndex(in streams: [JellyfinMediaStream]) -> Int? {
        guard isExternal != true else { return nil }
        return index - streams.filter { $0.isExternal == true }.count
    }
}

/// Another device playing something for this user (verified against Jellyfin 12.3.0).
public struct JellyfinSession: Decodable, Identifiable, Equatable, Sendable {
    public struct PlayState: Decodable, Equatable, Sendable {
        public var positionTicks: Int64?
        public var isPaused: Bool?
        public var mediaSourceId: String?
        public var audioStreamIndex: Int?
    }

    public var id: String
    public var userId: String?
    public var deviceId: String?
    public var deviceName: String?
    public var client: String?
    public var nowPlayingItem: JellyfinItem?
    public var playState: PlayState?
    /// When the client last reported its position.
    public var lastPlaybackCheckIn: Date?
    public var supportsRemoteControl: Bool?

    public var isPaused: Bool { playState?.isPaused ?? false }

    /// The position `/Sessions` reported, in seconds. For a playing session Jellyfin has
    /// already advanced it since the client's last report (see `LiveClock`).
    public var reportedPosition: Double { JellyfinTicks.seconds(playState?.positionTicks ?? 0) }

    /// The audio the other device is playing, as an FFmpeg stream index (for clips).
    public var ffmpegAudioIndex: Int? {
        guard let index = playState?.audioStreamIndex, let streams = nowPlayingItem?.mediaStreams,
              let stream = streams.first(where: { $0.index == index }) else { return nil }
        return stream.ffmpegIndex(in: streams)
    }
}

/// Remote-control commands for another device's player.
public enum JellyfinPlaystateCommand: String, Sendable {
    case pause = "Pause", unpause = "Unpause"
}

/// Where another device's playback is, between polls of `/Sessions`.
///
/// Measured on a Jellyfin server: for a playing session Jellyfin advances PositionTicks
/// itself between the client's reports, in whole seconds, so a reading lags the truth by up
/// to a second and never leads it. (Adding the time since `LastPlaybackCheckIn` on top
/// counted it twice: the feed ran ahead, then snapped back at each report.) So each reading
/// is a lower bound; the clock keeps the highest one seen and advances it locally.
public struct LiveClock: Equatable, Sendable {
    /// A reading this far behind the clock is a seek back, not a lagging reading.
    static let seekBack: TimeInterval = 2

    private var anchor: Double = 0
    private var anchoredAt: Date?
    public private(set) var isPaused = true

    public init() {}

    /// A position read from the server (or set by a command sent from here) at `date`.
    public mutating func observe(position: Double, paused: Bool, at date: Date) {
        defer { isPaused = paused }
        guard !paused, !isPaused, anchoredAt != nil else {
            anchor = position
            anchoredAt = date
            return
        }
        let predicted = self.position(at: date)
        if position > predicted || position < predicted - Self.seekBack {
            anchor = position
            anchoredAt = date
        }
    }

    public func position(at date: Date) -> Double {
        guard let anchoredAt else { return anchor }
        return isPaused ? anchor : anchor + max(date.timeIntervalSince(anchoredAt), 0)
    }
}

/// One size of a video's trickplay thumbnails: sheets (`tileWidth` × `tileHeight` thumbnails
/// each) taken every `interval` milliseconds.
public struct JellyfinTrickplayInfo: Decodable, Equatable, Hashable, Sendable {
    public var width: Int
    public var height: Int
    public var tileWidth: Int
    public var tileHeight: Int
    public var thumbnailCount: Int
    public var interval: Int

    public init(width: Int, height: Int, tileWidth: Int, tileHeight: Int, thumbnailCount: Int, interval: Int) {
        self.width = width
        self.height = height
        self.tileWidth = tileWidth
        self.tileHeight = tileHeight
        self.thumbnailCount = thumbnailCount
        self.interval = interval
    }

    /// Which sheet holds the thumbnail for `seconds`, and where in it (pixels).
    public func cell(at seconds: Double) -> (sheet: Int, x: Int, y: Int, width: Int, height: Int)? {
        guard interval > 0, thumbnailCount > 0, tileWidth > 0, tileHeight > 0 else { return nil }
        let index = min(max(Int(seconds * 1000) / interval, 0), thumbnailCount - 1)
        let perSheet = tileWidth * tileHeight
        let cell = index % perSheet
        return (index / perSheet, cell % tileWidth * width, cell / tileWidth * height, width, height)
    }
}

extension JellyfinItem {
    /// The trickplay size closest to `width` for a media source, if the server made any.
    public func trickplay(mediaSourceId: String, width: Int = 320) -> JellyfinTrickplayInfo? {
        (trickplay?[mediaSourceId] ?? trickplay?.values.first)?.values.min { abs($0.width - width) < abs($1.width - width) }
    }
}

/// A part of a video Jellyfin knows about (from e.g. the Intro Skipper plugin), in seconds.
public struct JellyfinMediaSegment: Codable, Equatable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case intro = "Intro", outro = "Outro", recap = "Recap", preview = "Preview", commercial = "Commercial"
    }

    public var kind: Kind
    public var start: Double
    public var end: Double

    public init(kind: Kind, start: Double, end: Double) {
        self.kind = kind
        self.start = start
        self.end = end
    }

    /// The segment playing at `time`, if any.
    public static func at(_ time: Double, in segments: [JellyfinMediaSegment]) -> JellyfinMediaSegment? {
        segments.first { $0.start <= time && time < $0.end }
    }
}

/// `/MediaSegments/{itemId}` as the server sends it.
struct JellyfinMediaSegmentsPage: Decodable {
    struct Item: Decodable {
        var type: String
        var startTicks: Int64
        var endTicks: Int64
    }

    var items: [Item]

    /// Known kinds only, in order, skipping empty ones.
    var segments: [JellyfinMediaSegment] {
        items.compactMap { item in
            guard let kind = JellyfinMediaSegment.Kind(rawValue: item.type), item.endTicks > item.startTicks else { return nil }
            return JellyfinMediaSegment(kind: kind, start: JellyfinTicks.seconds(item.startTicks), end: JellyfinTicks.seconds(item.endTicks))
        }
        .sorted { $0.start < $1.start }
    }
}

extension JellyfinItem {
    /// The AniDB anime id (Shoko puts it on seasons and series), if any.
    public var anidbId: Int? {
        providerIds?.first { $0.key.lowercased() == "anidb" }.flatMap { Int($0.value) }
    }
}
