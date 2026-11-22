import Foundation

/// The times playback stopped to wait for the stream (mpv's `paused-for-cache`) in one video:
/// how many, how long in all, and a line for the log as each ends (#143).
public struct StallLog: Sendable {
    public private(set) var count = 0
    public private(set) var seconds: Double = 0
    private var began: (at: Date, position: Double)?

    public init() {}

    /// Call when buffering starts or stops. Returns the log line when a wait ends.
    public mutating func note(buffering: Bool, at now: Date = .now, position: Double) -> String? {
        if buffering {
            if began == nil { began = (now, position) }
            return nil
        }
        guard let began else { return nil }
        self.began = nil
        let waited = now.timeIntervalSince(began.at)
        count += 1
        seconds += waited
        return "Waited \(Self.text(waited)) for the stream at \(Self.clock(began.position)) (wait \(count), \(Self.text(seconds)) in all)"
    }

    /// "2 waits · 5.3 s" for the stream info, nil when there were none.
    public var summary: String? {
        count == 0 ? nil : "\(count) \(count == 1 ? "wait" : "waits") · \(Self.text(seconds))"
    }

    static func text(_ seconds: Double) -> String {
        String(format: "%.1f s", seconds)
    }

    static func clock(_ position: Double) -> String {
        let total = Int(max(position, 0))
        return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total % 3600 / 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }
}
