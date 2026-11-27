import Foundation

/// Playback that should be moving but isn't (#143): started, not paused, not waiting for the
/// stream, yet the time stays put. `StallLog` covers the waits mpv reports itself; this catches
/// the hangs it doesn't (a read that never returns, a seek that never lands). Fed about once a
/// second; returns a line for the log when such a stretch starts and when it ends.
public struct StuckWatch: Sendable {
    /// How long the time may stay put while playing before it counts.
    public static let threshold: Double = 3
    public private(set) var count = 0
    public private(set) var seconds: Double = 0
    private var still: (position: Double, since: Date)?
    /// The stretch being reported: when it began, and where.
    private var stuck: (since: Date, position: Double)?

    public init() {}

    /// `playing`: playback should be moving (started, not paused, not buffering, not at the end).
    public mutating func check(position: Double, playing: Bool, at now: Date = .now) -> String? {
        guard playing else {
            still = nil
            return end(at: now, because: "paused or waiting for the stream")
        }
        if let still, abs(position - still.position) < 0.01 {
            guard stuck == nil, now.timeIntervalSince(still.since) >= Self.threshold else { return nil }
            stuck = (still.since, position)
            count += 1
            return "Stuck at \(StallLog.clock(position)) for \(StallLog.text(now.timeIntervalSince(still.since))) (not paused, not waiting for the stream; stuck \(count))"
        }
        still = (position, now)
        return end(at: now, because: "moving again")
    }

    /// "1 time · 7.0 s" for the stream info, nil when it never stuck.
    public var summary: String? {
        count == 0 ? nil : "\(count) \(count == 1 ? "time" : "times") · \(StallLog.text(seconds))"
    }

    private mutating func end(at now: Date, because reason: String) -> String? {
        guard let stuck else { return nil }
        self.stuck = nil
        let lasted = now.timeIntervalSince(stuck.since)
        seconds += lasted
        return "Was stuck at \(StallLog.clock(stuck.position)) for \(StallLog.text(lasted)), until \(reason)"
    }
}
