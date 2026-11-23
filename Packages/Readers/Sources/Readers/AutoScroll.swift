import Foundation
import Observation

/// Auto-scroll in the long strip and a book's Scroll layout: the reader asked for it, so it runs
/// (Reduce Motion included) until stopped, paused while something else has the reader's
/// attention, and stopped by itself when nobody has touched anything for `idleLimit`, so a
/// reader left open can't scroll through a book, count it as read and send that place on.
@MainActor @Observable
public final class AutoScroll {
    /// Why it isn't moving right now (it starts again when all are gone).
    public enum Pause: Hashable, Sendable {
        /// The reader's controls are showing.
        case controls
        /// A lookup is open.
        case lookup
        /// Scrolled by hand: it waits a moment, then carries on from there.
        case handScroll
        /// The app isn't in front.
        case background
        /// Choosing text by hand.
        case selecting
    }

    /// No touch, key, pointer move or lookup for this long: it stops.
    public nonisolated static let idleLimit: TimeInterval = 30 * 60
    /// After a scroll by hand, how long before it carries on.
    public static let resumeAfterHandScroll: Duration = .seconds(1)

    /// Its controls are on screen (from Auto-Scroll until closed; they stay after it stops by
    /// itself, showing play).
    public private(set) var isShown = false
    public private(set) var isOn = false
    public private(set) var pauses: Set<Pause> = []
    /// Stopped by the idle limit (the capsule says so once).
    public private(set) var stoppedIdle = false
    @ObservationIgnored private var lastInput = Date()
    @ObservationIgnored private var resumeTask: Task<Void, Never>?
    /// While on, paused or not: checks the idle limit every few seconds (the scroll loops stop
    /// while paused, and a reader put down with the controls up would keep the screen on).
    @ObservationIgnored private var idleTask: Task<Void, Never>?

    public init() {}

    /// Moving now: on, and nothing pausing it.
    public var isMoving: Bool { isOn && pauses.isEmpty }

    public func start(now: Date = .now) {
        isShown = true
        isOn = true
        stoppedIdle = false
        pauses.remove(.handScroll)
        lastInput = now
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, !Task.isCancelled, self.isOn else { return }
                self.checkIdle()
            }
        }
    }

    public func stop() {
        isOn = false
        resumeTask?.cancel()
        idleTask?.cancel()
        pauses.remove(.handScroll)
    }

    public func toggle() { isOn ? stop() : start() }

    /// Closed: stopped, and its controls gone.
    public func close() {
        stop()
        isShown = false
        stoppedIdle = false
    }

    public func set(_ pause: Pause, _ on: Bool) {
        if on { pauses.insert(pause) } else { pauses.remove(pause) }
    }

    /// A touch, key, pointer move or lookup: the idle limit starts again.
    public func noteInput(now: Date = .now) {
        lastInput = now
    }

    /// A finger (or wheel) began scrolling: paused while it does.
    public func handScrollBegan(now: Date = .now) {
        noteInput(now: now)
        resumeTask?.cancel()
        guard isOn else { return }
        pauses.insert(.handScroll)
    }

    /// The scroll by hand settled: on from there a moment later.
    public func handScrolled(now: Date = .now) {
        noteInput(now: now)
        guard isOn else { return }
        pauses.insert(.handScroll)
        resumeTask?.cancel()
        resumeTask = Task { [weak self] in
            try? await Task.sleep(for: Self.resumeAfterHandScroll)
            guard !Task.isCancelled else { return }
            self?.pauses.remove(.handScroll)
        }
    }

    /// Stops it once the idle limit has passed, moving or paused. Returns whether it stopped.
    @discardableResult
    public func checkIdle(now: Date = .now) -> Bool {
        guard isOn, Self.idleStops(lastInput: lastInput, now: now) else { return false }
        stop()
        stoppedIdle = true
        return true
    }

    public nonisolated static func idleStops(lastInput: Date, now: Date) -> Bool {
        now.timeIntervalSince(lastInput) >= idleLimit
    }

    // MARK: Speeds

    /// The long strip's levels, 1 to 10: points a second, from a slow read to a skim.
    public nonisolated static let mangaLevels = 1...10

    public nonisolated static func mangaPointsPerSecond(level: Int) -> Double {
        let level = Double(min(max(level, mangaLevels.lowerBound), mangaLevels.upperBound))
        // 20 pt/s at 1 to 200 pt/s at 10, evenly by ratio (each step about 29 % faster).
        return 20 * pow(10, (level - 1) / 9)
    }

    /// How long a book section with nothing to scroll stays before auto-scroll moves on: a
    /// picture page a fixed few seconds; text that fits on the screen the time its characters take
    /// at the chosen speed (at least 2 s), so it's read, not flashed by.
    public nonisolated static let pictureDwell: Double = 5
    public nonisolated static func dwellSeconds(picture: Bool, characters: Int, charactersPerMinute: Int) -> Double {
        if picture { return pictureDwell }
        guard charactersPerMinute > 0 else { return 2 }
        return max(Double(characters) / Double(charactersPerMinute) * 60, 2)
    }

    /// A book's reading speeds, in characters a minute.
    public nonisolated static let bookSpeeds = stride(from: 100, through: 1000, by: 50).map { $0 }

    /// How fast to scroll a book to read `charactersPerMinute`: lines go by at the rate their
    /// characters are read. `lineLength` is how much of the screen a line (a column in vertical
    /// text) spans, `fontSize` a character's size along it, `lineAdvance` from one line to the
    /// next, all in the same units.
    public nonisolated static func bookPointsPerSecond(charactersPerMinute: Int, fontSize: Double, lineAdvance: Double,
                                                       lineLength: Double) -> Double {
        guard fontSize > 0, lineLength > 0, lineAdvance > 0 else { return 0 }
        let charactersPerLine = max(lineLength / fontSize, 1)
        return Double(charactersPerMinute) / 60 / charactersPerLine * lineAdvance
    }
}
