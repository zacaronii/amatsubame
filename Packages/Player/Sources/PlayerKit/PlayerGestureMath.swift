import Foundation

/// The arithmetic behind the player's touch gestures, kept free of UI so it can be tested.
public enum PlayerGestureMath {
    public enum Side: Equatable, Sendable {
        case left, middle, right
    }

    /// Which third of the width a point is in (double-tap to skip).
    public static func third(x: Double, width: Double) -> Side {
        guard width > 0 else { return .middle }
        switch x / width {
        case ..<(1.0 / 3): return .left
        case (2.0 / 3)...: return .right
        default: return .middle
        }
    }

    /// Which edge strip a vertical drag started in (left brightness, right volume), if any.
    public static func edge(x: Double, width: Double, fraction: Double = 0.2) -> Side? {
        guard width > 0 else { return nil }
        if x < width * fraction { return .left }
        if x > width * (1 - fraction) { return .right }
        return nil
    }

    /// Seconds a full-width drag covers: 90 s, less for short videos (a quarter of them, at least 10 s).
    public static func secondsPerWidth(duration: Double) -> Double {
        min(90, max(duration / 4, 10))
    }

    /// Where a horizontal drag of `dx` points lands, clamped to the video.
    public static func scrubTarget(from start: Double, dx: Double, width: Double, duration: Double) -> Double {
        guard width > 0, duration > 0 else { return start }
        let target = start + dx / width * secondsPerWidth(duration: duration)
        return min(max(target, 0), duration)
    }

    /// A vertical drag of `dy` points (up is negative) changes a 0…1 level by the drag's share of the height.
    public static func level(from start: Double, dy: Double, height: Double) -> Double {
        guard height > 0 else { return start }
        return min(max(start - dy / (height * 0.8), 0), 1)
    }
}

/// Double-taps on the same side within `window` seconds add up: −10, −20, −30 s…
public struct SkipAccumulator: Equatable, Sendable {
    public static let step: Double = 10
    public var side: PlayerGestureMath.Side?
    public var total: Double = 0
    public var last: Date = .distantPast
    public var window: TimeInterval = 1

    public init() {}

    /// Registers a double-tap and returns how far to seek for this tap (±10 s) — the running total is in `total`.
    public mutating func register(_ tapSide: PlayerGestureMath.Side, at date: Date) -> Double {
        guard tapSide != .middle else { return 0 }
        let delta = tapSide == .left ? -Self.step : Self.step
        if side == tapSide, date.timeIntervalSince(last) <= window {
            total += delta
        } else {
            side = tapSide
            total = delta
        }
        last = date
        return delta
    }
}
