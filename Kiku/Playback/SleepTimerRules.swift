import Foundation

/// The sleep timer's fade-out and shake to extend.
enum SleepTimerRules {
    /// The volume goes down over the last half minute before the timer stops playback.
    static let fadeLength: Double = 30
    /// After the timer stopped playback, a shake still brings it back for this long.
    static let shakeGrace: Double = 120

    /// Seconds of listening left before the timer stops playback (at the speed playing), when
    /// that's known.
    static func remaining(_ timer: PlaybackModel.SleepTimer, now: Date, time: Double, stopsAt end: Double, rate: Double) -> Double? {
        switch timer {
        case .minutes(_, let ends): ends.timeIntervalSince(now)
        case .endOfChapter(let chapterEnd): (chapterEnd - time) / max(rate, 0.1)
        case .endOfEpisode: end > 0 ? (end - time) / max(rate, 0.1) : nil
        }
    }

    /// Full until the last `fadeLength` seconds, then down to nothing.
    static func volume(remaining: Double?) -> Float {
        guard let remaining else { return 1 }
        return Float(min(max(remaining / fadeLength, 0), 1))
    }

    enum Shake: Equatable {
        /// A minutes timer running: it starts again from its full length.
        case restart(minutes: Int)
        /// A minutes timer stopped playback a moment ago: playing again, with it set once more.
        case resume(minutes: Int)
    }

    /// What a shake does. Only a timer of minutes is extended (End of Chapter and End of Episode
    /// already say where to stop); after it stops playback, for `shakeGrace`.
    static func shake(timer: PlaybackModel.SleepTimer?, lastMinutes: Int?, stoppedAt: Date?, now: Date) -> Shake? {
        if case .minutes(let minutes, _)? = timer { return .restart(minutes: minutes) }
        guard timer == nil, let lastMinutes, let stoppedAt, now.timeIntervalSince(stoppedAt) <= shakeGrace else { return nil }
        return .resume(minutes: lastMinutes)
    }
}
