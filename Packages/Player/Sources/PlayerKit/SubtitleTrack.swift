import Core
import Foundation

/// One subtitle line, with formatting tags removed.
public struct SubtitleCue: Equatable, Hashable, Sendable, Identifiable {
    /// Position in the track (sorted by start).
    public var id: Int
    public var start: Double
    public var end: Double
    /// Lines joined with "\n".
    public var text: String

    public init(id: Int, start: Double, end: Double, text: String) {
        self.id = id
        self.start = start
        self.end = end
        self.text = text
    }

    /// The text on one line, for lookups and the card's sentence.
    public var sentence: String {
        text.split(whereSeparator: \.isNewline).joined()
    }
}

/// A parsed subtitle track: cues sorted by start time, and lookup by time.
public struct SubtitleTrack: Equatable, Sendable {
    public let cues: [SubtitleCue]

    public init(cues: [SubtitleCue]) {
        self.cues = Self.mergingCopies(cues.sorted { ($0.start, $0.end) < ($1.start, $1.end) })
            .enumerated().map { index, cue in
                var cue = cue
                cue.id = index
                return cue
            }
    }

    /// Merges copies of one line drawn as many cues (see `TranscriptLines.mergingCopies`).
    static func mergingCopies(_ sorted: [SubtitleCue]) -> [SubtitleCue] {
        TranscriptLines.mergingCopies(sorted.map { ($0.start, $0.end, $0.text) })
            .map { SubtitleCue(id: 0, start: $0.start, end: $0.end, text: $0.text) }
    }

    /// Parses SRT (as Jellyfin serves every text track). Malformed blocks are skipped.
    public init(srt: String) {
        let normalized = srt.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}"))
        var cues: [SubtitleCue] = []
        for block in normalized.components(separatedBy: "\n\n") {
            var lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeFirst() }
            guard let timingIndex = lines.prefix(2).firstIndex(where: { $0.contains("-->") }),
                  let (start, end) = Self.timing(lines[timingIndex]) else { continue }
            let text = lines[(timingIndex + 1)...]
                .map { Self.stripTags($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            guard !text.isEmpty else { continue }
            cues.append(SubtitleCue(id: 0, start: start, end: end, text: text))
        }
        self.init(cues: cues)
    }

    /// The cues showing at `time` (overlapping cues can share a moment), earliest first.
    public func cues(at time: Double) -> [SubtitleCue] {
        // Cues are short and sorted by start; scan back from the last one that has started.
        guard let last = lastStarted(at: time) else { return [] }
        var showing: [SubtitleCue] = []
        var index = last
        while index >= 0 {
            let cue = cues[index]
            if cue.end > time { showing.append(cue) }
            // Nothing earlier than a minute before can still be on screen.
            if time - cue.start > 60 { break }
            index -= 1
        }
        return showing.reversed()
    }

    /// The line to act on at `time`: the one showing, else the last one that ended.
    public func currentOrPrevious(at time: Double) -> SubtitleCue? {
        cues(at: time).last ?? lastStarted(at: time).map { cues[$0] }
    }

    /// The first cue starting after `time` (a little slack so "next" never repeats the current one).
    public func next(after time: Double) -> SubtitleCue? {
        cues.first { $0.start > time + 0.05 }
    }

    /// The line before the one at `time`. Within the first second of a line, that's the previous
    /// line; later on, it's the start of the current line (like a music player's back button).
    public func previous(before time: Double) -> SubtitleCue? {
        guard let index = lastStarted(at: time) else { return nil }
        if time - cues[index].start > 1 { return cues[index] }
        return index > 0 ? cues[index - 1] : cues[index]
    }

    /// Always the line before the one on screen (or the last one shown, between lines): for
    /// the AirPods triple press, which takes a moment to register.
    public func lineBefore(_ time: Double) -> SubtitleCue? {
        guard let index = lastStarted(at: time) else { return nil }
        return index > 0 ? cues[index - 1] : cues[index]
    }

    /// Index of the last cue with `start <= time` (binary search).
    private func lastStarted(at time: Double) -> Int? {
        var low = 0, high = cues.count
        while low < high {
            let mid = (low + high) / 2
            if cues[mid].start <= time { low = mid + 1 } else { high = mid }
        }
        return low > 0 ? low - 1 : nil
    }

    static func timing(_ line: String) -> (Double, Double)? {
        let parts = line.components(separatedBy: "-->")
        guard parts.count == 2, let start = seconds(parts[0]), let end = seconds(parts[1].split(separator: " ", omittingEmptySubsequences: true).first.map(String.init) ?? "") else {
            return nil
        }
        return (start, max(end, start))
    }

    /// "01:02:03,456" (or with "." or without hours) → seconds.
    static func seconds(_ text: String) -> Double? {
        let fields = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard (2...3).contains(fields.count) else { return nil }
        var total = 0.0
        for field in fields {
            guard let value = Double(field) else { return nil }
            total = total * 60 + value
        }
        return total
    }

    /// Removes HTML-ish tags (`<i>`, `<font …>`), ASS override blocks (`{\an8}`) and invisible
    /// direction and zero-width marks (some files put a lone U+200E on its own line).
    static func stripTags(_ line: String) -> String {
        line.replacing(/<[^>]*>/, with: "").replacing(/\{\\[^}]*\}/, with: "")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacing(/[\u{200B}-\u{200F}\u{202A}-\u{202E}\u{2066}-\u{2069}\u{FEFF}]/, with: "")
    }
}
