import CoreGraphics
import Foundation
#if canImport(SwiftUI)
import SwiftUI
#endif

/// A subtitle line an engine decoded (embedded or a sidecar file), on the source's time axis.
public struct EngineCue: Sendable, Equatable {
    public var start: Double
    public var end: Double
    public var text: String

    public init(start: Double, end: Double, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

/// Where a seek ended up and how long it took.
public struct EngineSeek: Sendable {
    public var target: Double
    /// The displayed frame's time once it settled (nil: it never landed).
    public var landed: Double?
    public var seconds: Double

    public init(target: Double, landed: Double?, seconds: Double) {
        self.target = target
        self.landed = landed
        self.seconds = seconds
    }
}

/// What Miru's player needs from a video engine. Spike only: mpv (`MPVController`) and
/// AetherEngine (`AetherBridge`) implement it, so one lab can measure both the same way.
@MainActor
public protocol PlayerEngine: AnyObject {
    var engineName: String { get }
    /// The displayed frame's time (source seconds).
    var timePosition: Double { get }
    var duration: Double { get }
    var isPaused: Bool { get }
    var hasStarted: Bool { get }
    var reachedEnd: Bool { get }

    func load(_ url: URL, headers: [String: String], start: Double) async throws
    func setPaused(_ paused: Bool)
    func setSpeed(_ speed: Double)
    /// Seeks and waits until the picture is there (or `timeout` passes).
    func seekAndWait(to seconds: Double, exact: Bool, timeout: Double) async -> EngineSeek
    /// Pauses as close as it can to `time` while playing (Pause After Each Line): where it stopped.
    func pause(at time: Double, timeout: Double) async -> Double?
    /// The engine's decoded subtitle lines (embedded track `index`, or a file), if it decodes any.
    func selectSubtitle(index: Int?) async
    func addSubtitleFile(_ url: URL) async -> Int?
    func selectSecondarySubtitle(index: Int?) async
    var cues: [EngineCue] { get }
    var secondaryCues: [EngineCue] { get }
    /// A frame-exact still at `time`, off playback.
    func snapshot(at time: Double) async -> CGImage?
    /// Route, audio delivery, versions…
    var diagnostics: [String: String] { get }
    func shutdown()
    #if canImport(SwiftUI)
    /// The picture.
    var view: AnyView { get }
    #endif
}
