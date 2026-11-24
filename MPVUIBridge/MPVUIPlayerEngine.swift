import CoreGraphics
import Foundation
import ImageIO
import MPVUI
import PlayerEngine
import SwiftUI

/// Spike: MPVUI behind `PlayerEngine`, measured the same way as mpv (MPVController) and
/// AetherEngine. It lives in its own dynamic framework so MPVUI's static libmpv and FFmpeg bind
/// here, apart from MPVKit's in the app. `MPVUI_OUTPUT=metal|sampleBuffer` picks the output.
@MainActor
public final class MPVUIPlayerEngine: PlayerEngine {
    public let player: MPVPlayer
    public let engineName = "MPVUI"
    private var subtitleTrack: MPVMediaTrackIdentifier?
    private var secondaryTrack: MPVMediaTrackIdentifier?
    private var trackCues: [EngineCue] = []
    private var trackSecondaryCues: [EngineCue] = []
    /// Cues seen live through interception (`makeTextSubtitleStream`), for tracks the whole-track
    /// query can't read (ASS).
    private var liveCues: [EngineCue] = []
    private var liveTask: Task<Void, Never>?
    private var cueSource = "-"

    /// mpv's warnings and errors (and MPVUI's own), for the lab's results.
    public static var log: [String] = []

    public init() {
        let output: MPVPlayerConfiguration.VideoOutput =
            ProcessInfo.processInfo.environment["MPVUI_OUTPUT"] == "metal" ? .metal : .sampleBuffer
        player = MPVPlayer(configuration: .init(automaticallyPlays: true, videoOutput: output))
        player.logHandler = { message in
            let line = "[\(message.prefix)] \(message.level): \(message.message)"
            print(line, terminator: line.hasSuffix("\n") ? "" : "\n")
            Self.log.append(line)
        }
    }

    public var timePosition: Double { player.position.seconds }
    public var duration: Double { player.duration.seconds }
    public var isPaused: Bool { player.isPaused }
    public var hasStarted: Bool { player.hasVideoFrame }
    public var reachedEnd: Bool { player.state == .ended }

    public func load(_ url: URL, headers: [String: String], start: Double) async throws {
        // No headers parameter on load: mpv's own option, set first.
        if !headers.isEmpty {
            player.setProperty("http-header-fields", to: headers.map { "\($0.key): \($0.value)" }.joined(separator: ","))
        }
        player.load(url, playAutomatically: true, startTime: .seconds(start))
    }

    public func setPaused(_ paused: Bool) { paused ? player.pause() : player.play() }
    public func setSpeed(_ speed: Double) { player.setPlaybackRate(speed) }

    public func seekAndWait(to seconds: Double, exact: Bool, timeout: Double) async -> EngineSeek {
        let started = Date()
        let result = try? await player.seekAndWait(to: .seconds(seconds), timeout: .seconds(timeout))
        return EngineSeek(target: seconds, landed: result.map { _ in player.position.seconds },
                          seconds: Date().timeIntervalSince(started))
    }

    /// As Miru does with mpv: follow the published time and pause once it passes `time`.
    public func pause(at time: Double, timeout: Double) async -> Double? {
        let started = Date()
        while player.position.seconds < time, Date().timeIntervalSince(started) < timeout {
            try? await Task.sleep(for: .milliseconds(2))
        }
        player.pause()
        try? await Task.sleep(for: .milliseconds(300))
        return player.position.seconds >= time ? player.position.seconds : nil
    }

    // MARK: Subtitles

    /// `index`: mpv's subtitle track id. The whole track's cues come from
    /// `textSubtitleSnapshots(for:)` (SubRip, WebVTT, TTML, mov_text); otherwise (ASS) only
    /// what interception has shown so far.
    public func selectSubtitle(index: Int?) async {
        guard let index else {
            player.disableTrack(.subtitle)
            subtitleTrack = nil
            return
        }
        let track = MPVMediaTrackIdentifier(type: .subtitle, mpvID: index)
        subtitleTrack = track
        player.selectSubtitle(track, for: .primary)
        trackCues = await cues(of: track)
        if trackCues.isEmpty { startInterception() }
    }

    public func addSubtitleFile(_ url: URL) async -> Int? {
        guard let result = try? await player.loadExternalTrack(MPVExternalTrack(url: url, type: .subtitle)) else { return nil }
        return result.tracks.first?.id.mpvID
    }

    public func selectSecondarySubtitle(index: Int?) async {
        guard let index else { return }
        let track = MPVMediaTrackIdentifier(type: .subtitle, mpvID: index)
        secondaryTrack = track
        player.selectSubtitle(track, for: .secondary)
        trackSecondaryCues = await cues(of: track)
    }

    private func cues(of track: MPVMediaTrackIdentifier) async -> [EngineCue] {
        do {
            let snapshots = try await player.textSubtitleSnapshots(for: track)
            cueSource = "whole track"
            return snapshots.map { EngineCue(start: $0.startTime.seconds, end: $0.endTime.seconds, text: $0.snapshot.text) }
        } catch {
            cueSource = "whole track failed: \(error)"
            return []
        }
    }

    private func startInterception() {
        player.setTextSubtitleInterceptionEnabled(true)
        liveTask?.cancel()
        liveTask = Task { [weak self] in
            guard let stream = self?.player.makeTextSubtitleStream() else { return }
            for await snapshot in stream {
                guard let self, !snapshot.isEmpty else { continue }
                let now = self.player.position.seconds
                if self.liveCues.last?.text != snapshot.text {
                    self.liveCues.append(EngineCue(start: now, end: now, text: snapshot.text))
                }
            }
        }
        cueSource += "; live interception"
    }

    public var cues: [EngineCue] { trackCues.isEmpty ? liveCues : trackCues }
    public var secondaryCues: [EngineCue] { trackSecondaryCues }

    /// Subtitle tracks as (mpv id, codec, language).
    public var subtitleTracks: [(id: Int, codec: String, language: String?)] {
        player.subtitleTracks.map { ($0.id.mpvID, $0.codec ?? "-", $0.language) }
    }

    // MARK: Mining

    /// mpv's own screenshot of the frame at `time` (MPVUI has no frame API): seeks there,
    /// paused, and writes the video frame without subtitles.
    public func snapshot(at time: Double) async -> CGImage? {
        let wasPaused = player.isPaused
        player.pause()
        _ = try? await player.seekAndWait(to: .seconds(time), timeout: .seconds(20))
        let output = FileManager.default.temporaryDirectory.appending(path: "mpvui-snapshot-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: output) }
        player.executeCommand("screenshot-to-file", arguments: [output.path(percentEncoded: false), "video"])
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: output.path(percentEncoded: false)) {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if !wasPaused { player.play() }
        guard let source = CGImageSourceCreateWithURL(output as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    public var diagnostics: [String: String] {
        let video = player.mediaInformation
        return ["output": player.videoOutput.rawValue, "state": "\(player.state)", "cues": cueSource,
                "media": String(describing: video).prefix(300).description]
    }

    public func shutdown() {
        liveTask?.cancel()
        player.stop()
    }

    public var view: AnyView { AnyView(MPVVideoPlayer(player: player)) }
}

extension Duration {
    var seconds: Double {
        let (seconds, attoseconds) = components
        return Double(seconds) + Double(attoseconds) / 1e18
    }
}
