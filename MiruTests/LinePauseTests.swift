import Foundation
@testable import Miru
import Observation
import PlayerKit
import SwiftUI
import Testing

/// Pause After Each Line through `PlayerEngine.setTimeBoundary`: the model asks the engine to call
/// back as a line nears its end, and pauses only if that line is still the one ending.
@MainActor @Suite struct LinePauseTests {
    /// Two lines, the second overlapping the first and running on past it.
    let overlapping = SubtitleTrack(cues: [
        SubtitleCue(id: 0, start: 0, end: 2, text: "一"),
        SubtitleCue(id: 1, start: 1, end: 4, text: "二"),
    ])
    let separate = SubtitleTrack(cues: [
        SubtitleCue(id: 0, start: 0, end: 2, text: "一"),
        SubtitleCue(id: 1, start: 3, end: 5, text: "二"),
    ])

    func model(_ track: SubtitleTrack) -> (PlaybackModel, FakeEngine) {
        let engine = FakeEngine()
        let model = PlaybackModel(session: PlaybackSession(itemId: "E1", title: "Episode 1"),
                                  environment: PlayerEnvironment.preview(), engine: engine)
        model.useSubtitlesForTests(track)
        model.setPausesAfterLines(true)
        engine.hasStarted = true
        engine.isPaused = false
        return (model, engine)
    }

    @Test func pausesWhereTheEngineCallsBack() {
        let (model, engine) = model(separate)
        engine.play(to: 0.5, model)
        #expect(engine.boundary == 2 - 0.12)
        engine.play(to: 1.95, model)
        #expect(engine.pausedAt == [2 - 0.12], "at the boundary, not at the next tick")
    }

    @Test func notWhileAnotherLineCarriesOn() {
        let (model, engine) = model(overlapping)
        engine.play(to: 0.5, model)
        // Straight across the first line's end: by then the second line is showing too.
        engine.play(to: 2.5, model)
        #expect(engine.pausedAt.isEmpty)
        engine.play(to: 3.95, model)
        #expect(engine.pausedAt == [4 - 0.12])
    }

    @Test func afterASeekIntoTheEndItPausesOnTheNextStep() {
        let (model, engine) = model(separate)
        engine.play(to: 0.5, model)
        engine.seek(to: 4.95, model)
        #expect(engine.pausedAt.isEmpty, "not on the seek itself")
        engine.play(to: 4.97, model)
        #expect(engine.pausedAt == [4.97])
    }

    @Test func turningItOffClearsTheBoundary() {
        let (model, engine) = model(separate)
        engine.play(to: 0.5, model)
        model.setPausesAfterLines(false)
        #expect(engine.boundary == nil)
        engine.play(to: 1.95, model)
        #expect(engine.pausedAt.isEmpty)
    }

    @Test func fasterSpeedsStopEarlier() {
        let (model, engine) = model(separate)
        engine.setSpeed(2)
        engine.play(to: 0.5, model)
        #expect(engine.boundary == 2 - 0.24)
    }
}

/// A `PlayerEngine` with a precise clock (like AetherEngine's boundary observers): moving across
/// a boundary stops there first, fires it, then carries on.
@MainActor @Observable
final class FakeEngine: PlayerEngine {
    var engineName: String { "fake" }
    var timePosition: Double = 0
    var duration: Double = 1440
    var isPaused = true
    var reachedEnd = false
    var hasStarted = false
    var isBuffering = false
    var bufferPercent: Int?
    var streamSpeed: Double?
    var bufferWait = BufferWait()
    var averageBitRate: Double?
    var tracks: [PlayerTrack] = []
    var fileChapters: [(start: Double, title: String?)] = []
    var lastError: String?
    var volume: Double = 100
    var speed: Double = 1
    var isMuted = false
    var loop: (start: Double?, end: Double?) = (nil, nil)
    var videoAspect: Double?
    var streamInfo: [(label: String, value: String)] { [] }
    var subtitleNote: String { "" }

    @ObservationIgnored private(set) var boundary: Double?
    @ObservationIgnored private var boundaryAction: (@MainActor () -> Void)?
    @ObservationIgnored private(set) var pausedAt: [Double] = []

    /// Plays forward to `time` (firing a boundary on the way), then tells the model, as the
    /// player's `onChange(of: timePosition)` does.
    func play(to time: Double, _ model: PlaybackModel) {
        if let boundary, timePosition < boundary, time >= boundary {
            timePosition = boundary
            let action = boundaryAction
            self.boundary = nil
            boundaryAction = nil
            action?()
            if isPaused {
                model.timeChanged()
                return
            }
        }
        timePosition = time
        model.timeChanged()
    }

    func seek(to time: Double, _ model: PlaybackModel) {
        timePosition = time
        model.timeChanged()
    }

    func load(_ url: URL, headers: [String: String], start: Double) {}
    func shutdown() {}
    func setPaused(_ paused: Bool) {
        if paused, !isPaused { pausedAt.append(timePosition) }
        isPaused = paused
    }
    func seek(to seconds: Double) { timePosition = seconds }
    func seek(by seconds: Double) { timePosition += seconds }
    func setVolume(_ value: Double) { volume = value }
    func setSpeed(_ value: Double) { speed = value }
    func setMuted(_ muted: Bool) { isMuted = muted }
    func frameStep(forward: Bool) {}
    func setLoop(start: Double?, end: Double?) { loop = (start, end) }
    func setVideoEnabled(_ enabled: Bool) {}
    func setTimeBoundary(_ time: Double?, action: @escaping @MainActor () -> Void) {
        boundary = time
        boundaryAction = time == nil ? nil : action
    }
    func selectAudio(_ id: Int) {}
    func selectSubtitle(_ id: Int?) {}
    func showSubtitles(from url: URL?, headers: [String: String]) {}
    func attach(_ standIn: any PlayerStandIn) {}
    func detach() {}
    func standInReport(time: Double, paused: Bool, buffering: Bool, ended: Bool) {}
    func videoView(fills: Bool) -> AnyView { AnyView(Color.black) }
}
