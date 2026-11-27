import Foundation
import Observation
import SwiftUI

/// What Miru's player needs from a video engine. `PlaybackModel` and the views talk to this, never
/// to an engine directly, so another engine is one more conformance (docs/AETHER_PLAN.md). Today
/// `MPVController` is the only one.
///
/// Properties update on the main actor, and conformances are `@Observable`, so views and
/// `onChange` follow them like any model.
@MainActor public protocol PlayerEngine: AnyObject, Observable, Sendable {
    /// The engine's name for the stats sheet and logs ("mpv").
    var engineName: String { get }
    /// How it plays this file, for the player's menu and the log ("loopback route"); nil if
    /// there's nothing to add.
    var engineDetail: String? { get }

    // MARK: State
    var timePosition: Double { get }
    var duration: Double { get }
    var isPaused: Bool { get }
    var reachedEnd: Bool { get }
    /// The file has started playing at its start position. Before that, `timePosition` can
    /// still read 0 even when starting part-way in.
    var hasStarted: Bool { get }
    /// Waiting for more of the stream: the picture is frozen though nothing is paused.
    var isBuffering: Bool { get }
    /// How far a refill is while buffering (0…100), if the engine knows.
    var bufferPercent: Int? { get }
    /// While buffering: how fast the stream is arriving, in bits a second, once measured.
    var streamSpeed: Double? { get }
    /// How long the engine gathers before carrying on after running dry.
    var bufferWait: BufferWait { get }
    /// The video's average bit rate (its size over its length), nil until both are known.
    var averageBitRate: Double? { get }
    var tracks: [PlayerTrack] { get }
    /// The file's own chapters: start in seconds and title.
    var fileChapters: [(start: Double, title: String?)] { get }
    var lastError: String? { get }
    /// The engine's own volume, 0…100 (the system volume is separate).
    var volume: Double { get }
    /// Playback speed (1 = normal).
    var speed: Double { get }
    var isMuted: Bool { get }
    /// The A–B loop's ends, in seconds (nil while not set); cleared for each new file.
    var loop: (start: Double?, end: Double?) { get }
    /// The video's display aspect ratio (width / height) once known.
    var videoAspect: Double? { get }

    // MARK: Playback
    /// Plays `url`, sending `headers` with every request, from `start` seconds.
    func load(_ url: URL, headers: [String: String], start: Double)
    /// Stops playback and frees the engine. Call when the player closes.
    func shutdown()
    func setPaused(_ paused: Bool)
    func seek(to seconds: Double)
    func seek(by seconds: Double)
    /// 0…100.
    func setVolume(_ value: Double)
    /// Kept within 0.25×–4×.
    func setSpeed(_ value: Double)
    func setMuted(_ muted: Bool)
    /// One frame forward or back, paused.
    func frameStep(forward: Bool)
    /// Loops between `start` and `end`; nil clears that end.
    func setLoop(start: Double?, end: Double?)
    /// Video off while the app is in the background or another player shows it (audio keeps
    /// playing), and back on after.
    func setVideoEnabled(_ enabled: Bool)
    /// `action` runs once, as soon as playback moves forward across `time` without jumping (a
    /// seek doesn't count). Pause After Each Line uses it. Setting another boundary, or nil,
    /// replaces it; it's cleared once it fires.
    func setTimeBoundary(_ time: Double?, action: @escaping @MainActor () -> Void)

    // MARK: Tracks
    /// An audio track by `PlayerTrack.id`.
    func selectAudio(_ id: Int)
    /// Shows one of the engine's subtitle tracks (by `PlayerTrack.id`), or none.
    func selectSubtitle(_ id: Int?)
    /// Adds an external subtitle file the engine draws (e.g. English), or turns its subtitles
    /// off. The file loads in the background: the track appears in `tracks`, selected, once
    /// it's in.
    func showSubtitles(from url: URL?, headers: [String: String])

    // MARK: Another player in the engine's place (AirPlay video)
    /// `standIn` plays from here on: the engine pauses where it is and reports what the stand-in
    /// tells it (`standInReport`) until `detach()`.
    func attach(_ standIn: any PlayerStandIn)
    /// The engine reports for itself again (seek it to where the stand-in got to, then play).
    func detach()
    func standInReport(time: Double, paused: Bool, buffering: Bool, ended: Bool)

    // MARK: Drawing and info
    /// The picture, sized to its view; `fills` crops it to fill the view instead of fitting it.
    func videoView(fills: Bool) -> AnyView
    /// Rows for the stats sheet: what's decoding, at what size, dropped frames…
    var streamInfo: [(label: String, value: String)] { get }
    /// A note for UI tests: which of the engine's subtitle tracks it shows and the line it draws.
    var subtitleNote: String { get }
}

public extension PlayerEngine {
    var engineDetail: String? { nil }
    /// "AetherEngine, loopback route", or just the name.
    var engineSummary: String { [engineName, engineDetail].compactMap { $0 }.joined(separator: ", ") }
    func togglePause() { setPaused(!isPaused) }
    func load(_ url: URL, headers: [String: String] = [:]) { load(url, headers: headers, start: 0) }
    func showSubtitles(from url: URL?) { showSubtitles(from: url, headers: [:]) }
    func standInReport(time: Double, paused: Bool) { standInReport(time: time, paused: paused, buffering: false, ended: false) }
}

/// A track in the playing file (audio, video, subtitles).
public struct PlayerTrack: Identifiable, Equatable, Sendable {
    /// The engine's id for the track (`selectAudio`, `selectSubtitle`).
    public var id: Int
    /// "audio", "video" or "sub".
    public var type: String
    public var language: String?
    public var title: String?
    public var codec: String?
    public var isExternal: Bool
    public var isSelected: Bool
    /// The stream's index in the file (FFmpeg numbering), for `MediaClipper`.
    public var ffIndex: Int?

    public init(id: Int, type: String, language: String? = nil, title: String? = nil, codec: String? = nil,
                isExternal: Bool = false, isSelected: Bool = false, ffIndex: Int? = nil) {
        self.id = id
        self.type = type
        self.language = language
        self.title = title
        self.codec = codec
        self.isExternal = isExternal
        self.isSelected = isSelected
        self.ffIndex = ffIndex
    }
}

/// Another player playing in the engine's place (AirPlay video on a TV): while one is attached,
/// the transport goes to it, and the time, pause and speed it reports are the engine's, so
/// everything that follows the engine follows it. The engine waits, paused.
@MainActor public protocol PlayerStandIn: AnyObject {
    func setPaused(_ paused: Bool)
    func seek(to seconds: Double)
    func setSpeed(_ speed: Double)
}

/// `PlayerEngine.setTimeBoundary` for an engine that reports its time in steps (mpv's time
/// events): fires on the first step that crosses the time going forward, and not on a jump.
public struct TimeBoundary {
    /// Further than this in one step is a seek, not playback.
    public static let jump = 2.0
    public var time: Double
    public var action: @MainActor () -> Void

    public init(time: Double, action: @escaping @MainActor () -> Void) {
        self.time = time
        self.action = action
    }

    /// Whether moving from `old` to `new` reaches the boundary.
    public func isCrossed(from old: Double, to new: Double) -> Bool {
        old < time && new >= time && new - old <= Self.jump
    }
}
