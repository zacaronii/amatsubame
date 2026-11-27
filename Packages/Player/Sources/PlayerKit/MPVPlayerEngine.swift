import CoreGraphics
import Foundation
import ImageIO
import PlayerEngine
import SwiftUI

/// Spike: mpv behind `PlayerEngine`, measured the same way as AetherEngine. Pausing at a time
/// follows `timePosition` (updated on each mpv time event), as `PlaybackModel.timeChanged` does.
@MainActor
public final class MPVPlayerEngine: PlayerEngine {
    public let controller = MPVController()
    public let engineName = "mpv"
    private var location = ""
    private var headers: [String: String] = [:]

    public init() {}

    public var timePosition: Double { controller.timePosition }
    public var duration: Double { controller.duration }
    public var isPaused: Bool { controller.isPaused }
    public var hasStarted: Bool { controller.hasStarted }
    public var reachedEnd: Bool { controller.reachedEnd }

    public func load(_ url: URL, headers: [String: String], start: Double) async throws {
        location = url.isFileURL ? url.path(percentEncoded: false) : url.absoluteString
        self.headers = headers
        controller.load(url, headers: headers, start: start)
        controller.setPaused(false)
    }

    public func setPaused(_ paused: Bool) { controller.setPaused(paused) }
    public func setSpeed(_ speed: Double) { controller.setSpeed(speed) }

    public func seekAndWait(to seconds: Double, exact: Bool, timeout: Double) async -> EngineSeek {
        let started = Date()
        controller.seek(to: seconds)
        // Landed: mpv isn't seeking any more and the time is at the target.
        try? await Task.sleep(for: .milliseconds(10))
        var landed: Double?
        while Date().timeIntervalSince(started) < timeout {
            if controller.property("seeking") == "no", abs(controller.timePosition - seconds) < 1 {
                landed = controller.timePosition
                break
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return EngineSeek(target: seconds, landed: landed, seconds: Date().timeIntervalSince(started))
    }

    public func pause(at time: Double, timeout: Double) async -> Double? {
        let started = Date()
        while controller.timePosition < time, Date().timeIntervalSince(started) < timeout {
            try? await Task.sleep(for: .milliseconds(2))
        }
        controller.setPaused(true)
        try? await Task.sleep(for: .milliseconds(300))
        return controller.timePosition >= time ? controller.timePosition : nil
    }

    // Miru draws its own subtitles from files; mpv's decoded cues aren't read.
    public func selectSubtitle(index: Int?) async {}
    public func addSubtitleFile(_ url: URL) async -> Int? { nil }
    public func selectSecondarySubtitle(index: Int?) async {}
    public var cues: [EngineCue] { [] }
    public var secondaryCues: [EngineCue] { [] }

    /// MediaClipper's frame (FFmpeg decode from the stream, as mining does).
    public func snapshot(at time: Double) async -> CGImage? {
        let output = FileManager.default.temporaryDirectory.appending(path: "mpv-snapshot-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: output) }
        guard (try? await MediaClipper.frame(from: location, headers: headers, at: time, to: output)) != nil,
              let source = CGImageSourceCreateWithURL(output as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    public var diagnostics: [String: String] {
        ["hwdec": controller.property("hwdec-current") ?? "-", "vo": controller.property("current-vo") ?? "-",
         "audio": controller.property("audio-codec-name") ?? "-"]
    }

    public func shutdown() { controller.shutdown() }

    public var view: AnyView { AnyView(MPVVideoView(controller: controller)) }
}
