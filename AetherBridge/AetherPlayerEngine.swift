import AetherEngine
import AVFoundation
import Combine
import CoreGraphics
import Foundation
import PlayerEngine
import SwiftUI

/// Spike: AetherEngine behind Miru's `PlayerEngine`. Lives in its own dynamic framework so the
/// engine binds to its own FFmpeg (AetherLib*), not the static FFmpeg MPVKit links into the app.
@MainActor
public final class AetherPlayerEngine: PlayerEngine {
    public let engine: AetherEngine
    public let engineName = "AetherEngine"
    private var cancellables: Set<AnyCancellable> = []
    private var seekLandings: [UInt64: Double] = [:]
    private var lastSeekID: UInt64?
    private var url: URL?
    private var headers: [String: String] = [:]
    /// The engine's log lines (the `[FFmpeg]` line among them).
    public static var log: [String] = []

    public static func installLog() {
        EngineLog.handler = { line in
            Task { @MainActor in
                if log.count < 4000 { log.append(line) }
            }
        }
    }

    public init() throws {
        engine = try AetherEngine()
        engine.seekEvents.sink { [weak self] event in
            guard let self else { return }
            MainActor.assumeIsolated {
                if case .landed(let rendered) = event.outcome { self.seekLandings[event.id] = rendered }
                if case .began = event.outcome { self.lastSeekID = event.id }
            }
        }.store(in: &cancellables)
    }

    public var timePosition: Double { engine.clock.sourceTime }
    public var duration: Double { engine.duration }
    public var isPaused: Bool { engine.state == .paused }
    public var hasStarted: Bool { engine.hasFirstFrameReadyForDisplay }
    public var reachedEnd: Bool { engine.state == .ended }

    public func load(_ url: URL, headers: [String: String], start: Double) async throws {
        self.url = url
        self.headers = headers
        var options = LoadOptions()
        options.httpHeaders = headers
        // AETHER_NATIVE_SUBS=0: keep every subtitle track on the cue path (no AVPlayer rendering).
        options.prepareNativeSubtitles = ProcessInfo.processInfo.environment["AETHER_NATIVE_SUBS"] != "0"
        _ = try await engine.load(url: url, startPosition: start > 0 ? start : nil, options: options)
    }

    public func setPaused(_ paused: Bool) {
        if paused { engine.pause() } else { engine.play() }
    }

    public func setSpeed(_ speed: Double) {
        engine.setRate(Float(speed))
    }

    public func seekAndWait(to seconds: Double, exact: Bool, timeout: Double) async -> EngineSeek {
        let started = Date()
        let before = lastSeekID
        await engine.seek(to: seconds, exact: exact)
        // The seek's own id is the newest `.began` after the call.
        while Date().timeIntervalSince(started) < timeout {
            if let id = lastSeekID, id != before, seekLandings[id] != nil { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        let landed = lastSeekID.flatMap { $0 != before ? seekLandings[$0] : nil }
        // The displayed frame's source time once settled (the landing is on the currentTime axis).
        return EngineSeek(target: seconds, landed: landed.map { _ in engine.clock.sourceTime }, seconds: Date().timeIntervalSince(started))
    }

    /// Two ways, measured separately: AVPlayer's boundary observer on the item axis (the
    /// precise one, on the native route), else the clock polled every few ms (~10 Hz updates).
    public var pausesWithBoundaryObserver = true

    public func pause(at time: Double, timeout: Double) async -> Double? {
        let started = Date()
        if pausesWithBoundaryObserver, let player = engine.currentAVPlayer,
           let itemSeconds = engine.presentationAxisMap.itemSeconds(forSourceSeconds: time) {
            var fired = false
            let token = player.addBoundaryTimeObserver(forTimes: [NSValue(time: CMTime(seconds: itemSeconds, preferredTimescale: 90_000))],
                                                       queue: .main) {
                player.rate = 0
                MainActor.assumeIsolated { fired = true }
            }
            while !fired, Date().timeIntervalSince(started) < timeout { try? await Task.sleep(for: .milliseconds(5)) }
            player.removeTimeObserver(token)
            engine.pause()
            try? await Task.sleep(for: .milliseconds(300))
            return fired ? engine.clock.sourceTime : nil
        }
        while engine.clock.sourceTime < time, Date().timeIntervalSince(started) < timeout {
            try? await Task.sleep(for: .milliseconds(2))
        }
        engine.pause()
        try? await Task.sleep(for: .milliseconds(300))
        return engine.clock.sourceTime >= time ? engine.clock.sourceTime : nil
    }

    public func selectSubtitle(index: Int?) async {
        if let index { engine.selectSubtitleTrack(index: index) } else { engine.clearSubtitle() }
    }

    public func addSubtitleFile(_ url: URL) async -> Int? {
        engine.addExternalSubtitleTrack(ExternalSubtitleTrack(url: url, name: "File", language: "ja")).id
    }

    public func selectSecondarySubtitle(index: Int?) async {
        if let index { engine.selectSecondarySubtitleTrack(index: index) } else { engine.clearSecondarySubtitle() }
    }

    public var cues: [EngineCue] { engine.subtitleCues.map(Self.cue) }
    public var secondaryCues: [EngineCue] { engine.secondarySubtitleCues.map(Self.cue) }

    static func cue(_ cue: SubtitleCue) -> EngineCue {
        let text: String = switch cue.body {
        case .text(let text): text
        case .richText(let runs): runs.map(\.text).joined()
        case .image: "[image]"
        }
        return EngineCue(start: cue.startTime, end: cue.endTime, text: text)
    }

    /// The embedded subtitle tracks: (id, codec, language).
    public var subtitleTracks: [(id: Int, codec: String, language: String?)] {
        engine.subtitleTracks.map { ($0.id, $0.isNativelyRenderedSubtitle ? "\($0.codec)(native)" : $0.codec, $0.language) }
    }

    public func snapshot(at time: Double) async -> CGImage? {
        guard let extractor = engine.makeFrameExtractor() else { return nil }
        let image = await extractor.snapshot(at: time)
        await extractor.shutdown()
        return image
    }

    public var diagnostics: [String: String] {
        ["route": engine.videoRoute.rawValue, "audio": engine.audioDelivery.rawValue, "state": "\(engine.state)",
         "maxRate": "\(engine.maxSupportedRate)"]
    }

    public var nativePlayerLayer: AVPlayerLayer? { engine.nativePlayerLayer }

    public func shutdown() {
        engine.stop()
    }

    public var view: AnyView { AnyView(AetherPlayerSurface(engine: engine)) }
}
