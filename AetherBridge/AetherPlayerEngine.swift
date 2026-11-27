// Internal: AetherEngine's FFmpeg modules (AetherLib*) must not reach anything that imports this
// framework next to PlayerKit (MPVKit's FFmpeg), or their C headers clash.
internal import AetherEngine
import AVFoundation
import Combine
import Foundation
import Observation
import PlayerEngine
import SwiftUI

/// AetherEngine behind Miru's `PlayerEngine`: the opt-in second engine (docs/AETHER_PLAN.md,
/// phase 2). It lives in its own dynamic framework so the engine binds to its own FFmpeg
/// (AetherLib*), not the static FFmpeg MPVKit links into the app.
///
/// AetherEngine is an `ObservableObject`; this keeps `@Observable` copies of what the player
/// follows, updated from its publishers on the main actor. Nothing of AetherEngine's own shows in
/// this class's public interface (see the import).
@MainActor @Observable
public final class AetherPlayerEngine: PlayerEngine {
    @ObservationIgnored let engine: AetherEngine
    public var engineName: String { "AetherEngine" }
    public var engineDetail: String? { route == "none" ? nil : "\(route) route" }

    public private(set) var timePosition: Double = 0
    public private(set) var duration: Double = 0
    public private(set) var isPaused = true
    public private(set) var reachedEnd = false
    public private(set) var hasStarted = false
    public private(set) var isBuffering = false
    public var bufferPercent: Int? { nil }
    public var streamSpeed: Double? { nil }
    /// mpv's growing cache waits have no counterpart here.
    public var bufferWait: BufferWait { BufferWait() }
    public private(set) var averageBitRate: Double?
    public private(set) var tracks: [PlayerTrack] = []
    public private(set) var fileChapters: [(start: Double, title: String?)] = []
    public private(set) var lastError: String?
    public private(set) var volume: Double = 100
    public private(set) var speed: Double = 1
    public private(set) var isMuted = false
    public private(set) var loop: (start: Double?, end: Double?) = (nil, nil)
    public private(set) var videoAspect: Double?
    /// The route the engine chose for this file (native AVPlayer or software).
    public private(set) var route = "none"
    /// The engine's clock as it is now (the published time follows it about ten times a second).
    public var clockTime: Double { engine.clock.sourceTime }

    @ObservationIgnored private var cancellables: Set<AnyCancellable> = []
    @ObservationIgnored private weak var standIn: (any PlayerStandIn)?
    @ObservationIgnored private var boundary: TimeBoundary?
    @ObservationIgnored private var boundaryObserver: (player: AVPlayer, token: Any)?
    @ObservationIgnored private var videoEnabled = true

    public init() throws {
        engine = try AetherEngine()
        observe()
    }

    // MARK: Following the engine

    private func observe() {
        func onMain<T>(_ publisher: Published<T>.Publisher, _ apply: @escaping @MainActor (AetherPlayerEngine, T) -> Void) {
            publisher.sink { [weak self] value in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    apply(self, value)
                }
            }.store(in: &cancellables)
        }
        onMain(engine.clock.$sourceTime) { $0.clockMoved(to: $1) }
        onMain(engine.$state) { me, state in
            guard me.standIn == nil else { return }
            let paused = state == .paused || state == .idle || state == .ended
            if paused != me.isPaused { me.isPaused = paused }
            if (state == .ended) != me.reachedEnd { me.reachedEnd = state == .ended }
        }
        onMain(engine.$isBuffering) { me, buffering in
            guard me.standIn == nil, buffering != me.isBuffering else { return }
            me.isBuffering = buffering
        }
        onMain(engine.$duration) { me, duration in me.duration = duration }
        onMain(engine.$hasFirstFrameReadyForDisplay) { me, ready in
            if ready != me.hasStarted { me.hasStarted = ready }
            if ready { me.updateAspect() }
        }
        onMain(engine.$errorInfo) { me, error in
            if let error { me.lastError = "\(error.kind)" }
        }
        onMain(engine.$videoRoute) { me, route in
            me.route = route.rawValue
            me.armBoundary()
        }
        onMain(engine.$audioTracks) { me, _ in me.updateTracks() }
        onMain(engine.$subtitleTracks) { me, _ in me.updateTracks() }
        onMain(engine.$activeAudioTrackIndex) { me, _ in me.updateTracks() }
        onMain(engine.$mediaChapters) { me, chapters in
            me.fileChapters = chapters.map { (start: $0.startSeconds, title: $0.name.isEmpty ? nil : $0.name) }
        }
        onMain(engine.$sourceVideoWidth) { me, _ in me.updateAspect() }
        onMain(engine.$sourceVideoHeight) { me, _ in me.updateAspect() }
        onMain(engine.$sourceVideoBitrate) { me, bitrate in me.averageBitRate = bitrate > 0 ? Double(bitrate) : nil }
    }

    private func updateTracks() {
        let audio = engine.audioTracks.map {
            PlayerTrack(id: $0.id, type: "audio", language: $0.language, title: $0.name.isEmpty ? nil : $0.name,
                        codec: $0.codec, isSelected: $0.id == engine.activeAudioTrackIndex, ffIndex: $0.id)
        }
        let subtitles = engine.subtitleTracks.map {
            PlayerTrack(id: $0.id, type: "sub", language: $0.language, title: $0.name.isEmpty ? nil : $0.name,
                        codec: $0.codec, isSelected: $0.id == engine.activeSecondarySubtitleTrackIndex, ffIndex: $0.id)
        }
        let all = audio + subtitles
        if all != tracks { tracks = all }
    }

    /// The source's size when the engine reads it (software route), else what AVPlayer presents.
    private func updateAspect() {
        var size = CGSize(width: Double(engine.sourceVideoWidth), height: Double(engine.sourceVideoHeight))
        if size.width <= 0 || size.height <= 0, let item = engine.currentAVPlayerItem { size = item.presentationSize }
        guard size.width > 0, size.height > 0 else { return }
        let aspect = size.width / size.height
        if videoAspect.map({ abs($0 - aspect) / $0 > 0.005 }) ?? true { videoAspect = aspect }
    }

    /// The engine's clock moved (about ten times a second). On the software route this is where a
    /// boundary is checked; on the native route AVPlayer's boundary observer fires on time.
    private func clockMoved(to time: Double) {
        guard standIn == nil else { return }
        moveTime(to: time)
        if let end = loop.end, time >= end { seek(to: loop.start ?? 0) }
    }

    private func moveTime(to time: Double) {
        let old = timePosition
        guard abs(time - old) > 0.0005 else { return }
        timePosition = time
        if boundaryObserver == nil, let boundary, boundary.isCrossed(from: old, to: time) {
            fireBoundary(boundary)
        }
    }

    private func fireBoundary(_ boundary: TimeBoundary) {
        clearBoundaryObserver()
        self.boundary = nil
        // The clock trails the picture by up to a tenth of a second: what the boundary's
        // action reads is the boundary's time.
        if timePosition < boundary.time { timePosition = boundary.time }
        boundary.action()
    }

    // MARK: Playback

    public func load(_ url: URL, headers: [String: String], start: Double) {
        reachedEnd = false
        hasStarted = false
        lastError = nil
        isBuffering = false
        setLoop(start: nil, end: nil)
        var options = LoadOptions()
        options.httpHeaders = headers
        // Miru draws the Japanese lines itself, and English from `showSubtitles`: no subtitle of
        // the engine's own is drawn by AVPlayer.
        options.prepareNativeSubtitles = false
        let muted = Self.testMuted
        if muted { engine.volume = 0 }
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.engine.load(url: url, startPosition: start > 0 ? start : nil, options: options)
                self.engine.clearSubtitle()
                if muted { self.engine.volume = 0 }
                self.armBoundary()
            } catch {
                self.lastError = error.localizedDescription
            }
        }
    }

    /// UI tests and recordings (`UITEST_MUTE=1`, Debug builds only): silent from the first frame.
    private static var testMuted: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["UITEST_MUTE"] != nil
        #else
        false
        #endif
    }

    public func shutdown() {
        clearBoundaryObserver()
        cancellables.removeAll()
        engine.stop()
    }

    public func setPaused(_ paused: Bool) {
        if let standIn {
            standIn.setPaused(paused)
            return
        }
        if paused { engine.pause() } else { engine.play() }
    }

    public func seek(to seconds: Double) {
        let target = max(seconds, 0)
        if let standIn {
            standIn.seek(to: target)
            return
        }
        Task { await engine.seek(to: target, exact: true) }
    }

    public func seek(by seconds: Double) {
        seek(to: timePosition + seconds)
    }

    public func setVolume(_ value: Double) {
        volume = min(max(value, 0), 100)
        if !isMuted, !Self.testMuted { engine.volume = Float(volume / 100) }
    }

    public func setSpeed(_ value: Double) {
        speed = (min(max(value, 0.25), 4) * 100).rounded() / 100
        engine.setRate(Float(speed))
        standIn?.setSpeed(speed)
    }

    public func setMuted(_ muted: Bool) {
        isMuted = muted
        engine.volume = muted || Self.testMuted ? 0 : Float(volume / 100)
    }

    /// One frame on the native route (AVPlayer steps); the software route has no stepping.
    public func frameStep(forward: Bool) {
        guard standIn == nil, let item = engine.currentAVPlayerItem else { return }
        engine.pause()
        item.step(byCount: forward ? 1 : -1)
    }

    public func setLoop(start: Double?, end: Double?) {
        loop = (start, end)
    }

    /// In the background the picture is detached from AVPlayer, so audio plays on (an AVPlayer
    /// with a visible layer pauses when the app leaves).
    public func setVideoEnabled(_ enabled: Bool) {
        guard enabled != videoEnabled else { return }
        videoEnabled = enabled
        engine.nativePlayerLayer?.player = enabled ? engine.currentAVPlayer : nil
    }

    // MARK: Line pauses

    public func setTimeBoundary(_ time: Double?, action: @escaping @MainActor () -> Void) {
        boundary = time.map { TimeBoundary(time: $0, action: action) }
        armBoundary()
    }

    /// On the native route, AVPlayer's own boundary observer (the spike measured 1.6–2.0 ms at
    /// 1×); elsewhere the clock checks it (`moveTime`).
    private func armBoundary() {
        clearBoundaryObserver()
        guard let boundary, standIn == nil, let player = engine.currentAVPlayer,
              let itemSeconds = engine.presentationAxisMap.itemSeconds(forSourceSeconds: boundary.time) else { return }
        let token = player.addBoundaryTimeObserver(forTimes: [NSValue(time: CMTime(seconds: itemSeconds, preferredTimescale: 90_000))],
                                                   queue: .main) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let boundary = self.boundary else { return }
                self.fireBoundary(boundary)
            }
        }
        boundaryObserver = (player, token)
    }

    private func clearBoundaryObserver() {
        guard let boundaryObserver else { return }
        boundaryObserver.player.removeTimeObserver(boundaryObserver.token)
        self.boundaryObserver = nil
    }

    // MARK: Tracks

    public func selectAudio(_ id: Int) {
        engine.selectAudioTrack(index: id)
    }

    /// The engine's own subtitle track Miru shows (English, at the top), or none.
    public func selectSubtitle(_ id: Int?) {
        if let id { engine.selectSecondarySubtitleTrack(index: id) } else { engine.clearSecondarySubtitle() }
        updateTracks()
    }

    public func showSubtitles(from url: URL?, headers: [String: String]) {
        if let url {
            engine.selectSecondarySidecarSubtitle(url: url, httpHeaders: headers.isEmpty ? nil : headers)
        } else {
            engine.clearSecondarySubtitle()
        }
        updateTracks()
    }

    // MARK: Another player in the engine's place

    public func attach(_ standIn: any PlayerStandIn) {
        engine.pause()
        self.standIn = standIn
        clearBoundaryObserver()
        isBuffering = false
    }

    public func detach() {
        standIn = nil
        isPaused = true
        isBuffering = false
        reachedEnd = false
        armBoundary()
    }

    public func standInReport(time: Double, paused: Bool, buffering: Bool, ended: Bool) {
        guard standIn != nil else { return }
        if time.isFinite { moveTimeFromStandIn(to: max(time, 0)) }
        if paused != isPaused { isPaused = paused }
        if buffering != isBuffering { isBuffering = buffering }
        if ended != reachedEnd { reachedEnd = ended }
    }

    private func moveTimeFromStandIn(to time: Double) {
        let old = timePosition
        guard abs(time - old) > 0.0005 else { return }
        timePosition = time
        if let boundary, boundary.isCrossed(from: old, to: time) { fireBoundary(boundary) }
    }

    // MARK: Drawing and info

    public func videoView(fills: Bool) -> AnyView {
        AnyView(AetherPlayerSurface(engine: engine))
    }

    public var streamInfo: [(label: String, value: String)] {
        var rows: [(label: String, value: String)] = [("Engine", "AetherEngine, \(route) route")]
        let width = engine.sourceVideoWidth, height = engine.sourceVideoHeight
        let video = [engine.sourceVideoCodecName, width > 0 && height > 0 ? "\(width)×\(height)" : nil,
                     engine.sourceVideoFrameRate.flatMap { $0 > 0 ? String(format: "%.3f fps", $0) : nil }]
            .compactMap { $0 }.joined(separator: " · ")
        if !video.isEmpty { rows.append(("Video", video)) }
        if let decoder = engine.activeVideoDecoder { rows.append(("Decoding", decoder)) }
        let audio = [engine.activeAudioDecoder, engine.audioDelivery.rawValue].compactMap { $0 }.joined(separator: " · ")
        if !audio.isEmpty { rows.append(("Audio", audio)) }
        return rows
    }

    public var subtitleNote: String {
        let line = engine.secondarySubtitleCues.first { $0.startTime <= timePosition && timePosition < $0.endTime }
        return "engine sid: \(engine.activeSecondarySubtitleTrackIndex.map(String.init) ?? "no")"
            + (line.map { ", engine line: \(Self.text($0))" } ?? "")
    }

    static func text(_ cue: SubtitleCue) -> String {
        switch cue.body {
        case .text(let text): text
        case .richText(let runs): runs.map(\.text).joined()
        case .image: ""
        }
    }
}
