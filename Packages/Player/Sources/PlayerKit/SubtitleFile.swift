import Foundation

/// Text subtitle files from outside Jellyfin (e.g. Jimaku): SRT and ASS/SSA, in whatever
/// encoding they came in, and their timing shifted to match the user's release.
public enum SubtitleFile {
    public enum Format: String, Sendable, Codable {
        case srt, ass, ssa
    }

    /// The format from the file name, else from the content; nil when it's neither.
    public static func format(fileName: String, text: String? = nil) -> Format? {
        switch (fileName as NSString).pathExtension.lowercased() {
        case "srt": return .srt
        case "ass": return .ass
        case "ssa": return .ssa
        default: break
        }
        guard let text else { return nil }
        if text.contains("[Events]") && text.contains("Dialogue:") { return .ass }
        if text.contains("-->") { return .srt }
        return nil
    }

    /// The file as text: UTF-8 or UTF-16 (with a byte-order mark), else Shift-JIS, which
    /// older Japanese subtitle files often use.
    public static func decode(_ data: Data) -> String? {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16)
        }
        if let text = String(data: data, encoding: .utf8) {
            return text.trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}")).isEmpty ? nil : text
        }
        return String(data: data, encoding: .shiftJIS)
    }

    /// The lines of a file.
    public static func track(_ text: String, format: Format) -> SubtitleTrack {
        format == .srt ? SubtitleTrack(srt: text) : SubtitleTrack(ass: text)
    }

    /// The same file with every time moved by `seconds` (positive = later), keeping everything
    /// else (ASS styling included) as it was. Times never go below zero.
    public static func shifted(_ text: String, format: Format, by seconds: Double) -> String {
        guard seconds != 0 else { return text }
        return retimed(text, format: format) { _ in seconds }
    }

    /// The same file with each line moved by `shift(its start time)` (a sync's parts), both
    /// its start and end, so lines keep their length. Everything else stays as it was.
    public static func retimed(_ text: String, format: Format, shift: (Double) -> Double) -> String {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        switch format {
        case .srt:
            return lines.map { line in
                guard line.contains("-->"), let (start, end) = SubtitleTrack.timing(line) else { return line }
                let seconds = shift(start)
                return "\(srtTime(start + seconds)) --> \(srtTime(end + seconds))"
            }
            .joined(separator: "\n")
        case .ass, .ssa:
            var fields = ASSEvents.defaultFields
            return lines.map { line in
                if let format = ASSEvents.formatFields(line) { fields = format }
                guard var event = ASSEvents.dialogue(line, fields: fields) else { return line }
                let start = ASSEvents.seconds(event.values[event.startIndex]) ?? 0
                let seconds = shift(start)
                event.values[event.startIndex] = assTime(start + seconds)
                event.values[event.endIndex] = assTime((ASSEvents.seconds(event.values[event.endIndex]) ?? 0) + seconds)
                return event.prefix + event.values.joined(separator: ",")
            }
            .joined(separator: "\n")
        }
    }

    static func srtTime(_ seconds: Double) -> String {
        let millis = Int((max(seconds, 0) * 1000).rounded())
        return String(format: "%02d:%02d:%02d,%03d", millis / 3_600_000, millis / 60_000 % 60, millis / 1000 % 60, millis % 1000)
    }

    static func assTime(_ seconds: Double) -> String {
        let centis = Int((max(seconds, 0) * 100).rounded())
        return String(format: "%d:%02d:%02d.%02d", centis / 360_000, centis / 6000 % 60, centis / 100 % 60, centis % 100)
    }
}

/// The `[Events]` part of an ASS/SSA file.
enum ASSEvents {
    /// Used when a file has no `Format:` line (the ASS default).
    static let defaultFields = ["layer", "start", "end", "style", "name", "marginl", "marginr", "marginv", "effect", "text"]

    struct Event {
        /// "Dialogue: " (kept so a rewrite leaves the line as it was).
        var prefix: String
        var values: [String]
        var startIndex: Int
        var endIndex: Int
        var fields: [String]

        func value(_ field: String) -> String? {
            fields.firstIndex(of: field).flatMap { values.indices.contains($0) ? values[$0] : nil }
        }
    }

    /// The field names of a `Format:` line in the events section.
    static func formatFields(_ line: String) -> [String]? {
        guard line.hasPrefix("Format:"), line.lowercased().contains("text") else { return nil }
        return line.dropFirst("Format:".count).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
    }

    /// A `Dialogue:` line split into its fields (the text keeps its commas).
    static func dialogue(_ line: String, fields: [String]) -> Event? {
        guard line.hasPrefix("Dialogue:"), let start = fields.firstIndex(of: "start"), let end = fields.firstIndex(of: "end") else {
            return nil
        }
        let body = line.dropFirst("Dialogue:".count)
        let leading = body.prefix { $0 == " " }
        let values = body.dropFirst(leading.count).split(separator: ",", maxSplits: fields.count - 1, omittingEmptySubsequences: false)
            .map(String.init)
        guard values.count == fields.count else { return nil }
        return Event(prefix: "Dialogue:" + leading, values: values, startIndex: start, endIndex: end, fields: fields)
    }

    /// "0:01:02.34" → seconds.
    static func seconds(_ text: String) -> Double? {
        SubtitleTrack.seconds(text)
    }

    /// A style marked Japanese ("Default - JP", "Dialogue_JA", "日文").
    static func isJapaneseStyle(_ style: String) -> Bool {
        style.lowercased().contains(/(^|[^a-z])(jp|ja|jpn|jap|japanese)($|[^a-z])/) || style.contains(/日[文语語]/)
    }

    /// Signs, songs and karaoke rather than dialogue: by style or name, by an effect (karaoke
    /// templates render songs letter by letter as "fx" lines), or by karaoke timing tags.
    static func isDecoration(_ event: Event) -> Bool {
        let label = [event.value("style"), event.value("name")].compactMap(\.self).joined(separator: " ").lowercased()
        if label.contains(/sign|song|kara|lyric|^(op|ed)(\b|_)|\b(op|ed)\b/) { return true }
        if let effect = event.value("effect")?.lowercased(), effect.contains(/fx|karaoke|template|banner|scroll/) { return true }
        return event.value("text")?.contains(/\\[kK][fo]?\d/) == true
    }
}

extension SubtitleTrack {
    /// Parses ASS/SSA dialogue: override tags removed, `\N` as a line break, drawings and
    /// sign, song and karaoke styles left out (they'd clutter the line list).
    public init(ass: String) {
        var fields = ASSEvents.defaultFields
        var inEvents = false
        var cues: [(style: String, cue: SubtitleCue)] = []
        for raw in ass.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}"))
            if line.hasPrefix("[") {
                inEvents = line.lowercased().hasPrefix("[events]")
                continue
            }
            guard inEvents else { continue }
            if let format = ASSEvents.formatFields(line) {
                fields = format
                continue
            }
            guard let event = ASSEvents.dialogue(line, fields: fields), !ASSEvents.isDecoration(event),
                  let text = event.value("text"),
                  let start = ASSEvents.seconds(event.values[event.startIndex]),
                  let end = ASSEvents.seconds(event.values[event.endIndex]) else { continue }
            // Vector drawings (\p1 and up) aren't text.
            if text.contains(/\\p[1-9]/) { continue }
            let cleaned = text.replacing(/\{[^}]*\}/, with: "")
                .replacingOccurrences(of: "\\N", with: "\n").replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\\h", with: " ")
                .split(separator: "\n").map { Self.stripTags(String($0)).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            guard !cleaned.isEmpty else { continue }
            cues.append((event.value("style") ?? "", SubtitleCue(id: 0, start: start, end: max(end, start), text: cleaned)))
        }
        // Bilingual files (e.g. "Default - CN" and "Default - JP"): only the Japanese styles.
        let japanese = cues.filter { ASSEvents.isJapaneseStyle($0.style) }
        self.init(cues: (japanese.isEmpty ? cues : japanese).map(\.cue))
    }

    /// The same lines `seconds` later (earlier when negative), never before zero.
    public func offset(by seconds: Double) -> SubtitleTrack {
        guard seconds != 0 else { return self }
        return SubtitleTrack(cues: cues.map { cue in
            var cue = cue
            cue.start = max(cue.start + seconds, 0)
            cue.end = max(cue.end + seconds, 0)
            return cue
        })
    }
}
