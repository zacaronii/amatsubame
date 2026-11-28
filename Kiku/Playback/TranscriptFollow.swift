import Core
import Foundation
import KikuWatchLink

/// Which transcript line goes with a playback time, and where the line buttons jump.
enum TranscriptFollow {
    /// The line playing at `time`: the last one started by then (it stays current through the
    /// pause after it). Nil before the first line. Live Text on the watch follows the same way.
    static func index(at time: Double, in sentences: [AudioSentence]) -> Int? {
        LineFollow.index(at: time, in: sentences, start: \.start)
    }

    /// Playing again after a pause: where to pick up, so the line that was cut off is heard
    /// whole (other apps rewind a few seconds; here the line's start is known). Nil when there's
    /// nothing to do: the pause was a moment, there's no line, or its start is too far back.
    static func resumeTarget(at time: Double, in sentences: [AudioSentence], pausedFor pause: Double) -> Double? {
        guard pause >= 2, let index = index(at: time, in: sentences) else { return nil }
        let line = sentences[index]
        // Only inside the line (not in the gap after it), and not a long way back.
        guard time < line.end, time - line.start > 0.3, time - line.start <= 20 else { return nil }
        return line.start
    }

    /// Pause After Each Line and Repeat Line: the line that has just ended at `time`, when
    /// `previous` was the line playing a moment ago (it ends before the next begins, or as it does).
    static func lineJustEnded(at time: Double, previous: Int?, in sentences: [AudioSentence]) -> Int? {
        guard let previous, sentences.indices.contains(previous), time >= sentences[previous].end else { return nil }
        // Not after a jump far past it.
        return time - sentences[previous].end < 2 ? previous : nil
    }

    /// How far into a line "previous" restarts it rather than going back one.
    static let restartAfter = 2.0

    /// Previous line, like a music app's back button: restart the current line once you're more
    /// than two seconds in, otherwise the line before it.
    static func previousTarget(from time: Double, in sentences: [AudioSentence]) -> Double {
        guard let index = index(at: time, in: sentences) else { return 0 }
        if time - sentences[index].start > restartAfter { return sentences[index].start }
        return index > 0 ? sentences[index - 1].start : sentences[index].start
    }

    /// The next line's start; nil after the last one.
    static func nextTarget(from time: Double, in sentences: [AudioSentence]) -> Double? {
        let next = (index(at: time, in: sentences) ?? -1) + 1
        return next < sentences.count ? sentences[next].start : nil
    }

    /// A mark this soon into a line is about the line before it (people mark a second or two late).
    static let markLate = 3.0

    /// The line a mark is most likely about: the one that ended just before it, unless the mark
    /// is well into the line playing (that line, then). With `guessesEarlier` off (the player's
    /// button, pressed looking at the line) it's the line playing. Nil for an empty transcript.
    static func markedIndex(at time: Double, in sentences: [AudioSentence], guessesEarlier: Bool = true) -> Int? {
        guard !sentences.isEmpty else { return nil }
        guard let current = index(at: time, in: sentences) else { return 0 }
        return guessesEarlier && current > 0 && time - sentences[current].start < markLate ? current - 1 : current
    }

    /// The lines shown under a mark: the likely one with one before and one after.
    static func markWindow(at time: Double, in sentences: [AudioSentence], guessesEarlier: Bool = true)
        -> (lines: ArraySlice<AudioSentence>, marked: Int)? {
        guard let marked = markedIndex(at: time, in: sentences, guessesEarlier: guessesEarlier) else { return nil }
        return (sentences[max(marked - 1, 0)...min(marked + 1, sentences.count - 1)], marked)
    }
}

/// "4 new" under a show: episodes not started yet, published after the newest one you've
/// started (a show you've never played counts the last two weeks). Audiobookshelf has no
/// "new" flag of its own.
enum EpisodeNews {
    static let unplayedWindow: TimeInterval = 14 * 24 * 3600

    static func newCount(episodes: [(published: Date?, started: Bool)], now: Date = .now) -> Int {
        let newestStarted = episodes.filter(\.started).compactMap(\.published).max()
        let since = newestStarted ?? now.addingTimeInterval(-unplayedWindow)
        return episodes.filter { !$0.started && ($0.published ?? .distantPast) > since }.count
    }
}

extension Double {
    /// "13:09" or "1:02:15".
    var clockText: String {
        let total = Int(Swift.max(self, 0))
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }

    /// "23 min", "1 h 4 min".
    var lengthText: String {
        let minutes = Int((Swift.max(self, 0) / 60).rounded())
        if minutes < 60 { return "\(Swift.max(minutes, 1)) min" }
        return minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min"
    }
}
