import Foundation

/// How long to gather video after the stream runs dry before playing on. mpv's own answer is one
/// second, which on a connection slower than the video means stopping every few seconds. This
/// starts short and steps up each time the stream runs dry again soon after the last wait, and
/// goes back down once playback has run a good while without one. A wait right after a seek is
/// the seek's own refill and doesn't count.
public struct BufferWait: Equatable, Sendable {
    /// Seconds of video to gather, by step.
    public static let steps = [2, 6, 12, 20]
    /// Running dry again within this long of the last wait's end is "again soon".
    static let again: TimeInterval = 90
    static let afterSeek: TimeInterval = 3

    public private(set) var step = 0
    private var lastEnd: Date?
    private var lastSeek: Date?

    public init() {}

    public var seconds: Int { Self.steps[step] }

    public mutating func noteSeek(at now: Date = .now) {
        lastSeek = now
    }

    /// Call when buffering starts or stops. True when `seconds` changed.
    public mutating func note(buffering: Bool, at now: Date = .now) -> Bool {
        guard buffering else {
            lastEnd = now
            return false
        }
        if let lastSeek, now.timeIntervalSince(lastSeek) < Self.afterSeek { return false }
        let before = step
        if let lastEnd, now.timeIntervalSince(lastEnd) < Self.again {
            step = min(step + 1, Self.steps.count - 1)
        } else if lastEnd != nil {
            step = max(step - 1, 0)
        }
        return step != before
    }
}
