import Foundation

/// An episode's transcript for Live Text. The watch asks for it when the state names one it
/// hasn't got, and the phone sends it in parts (`part(from:)`) that fit a WatchConnectivity
/// message. Word timings aren't needed: the watch follows lines, and the phone does lookups.
public struct WatchTranscript: Codable, Equatable, Sendable {
    public struct Line: Codable, Equatable, Sendable {
        /// Its place in the transcript, from 0 (the phone's `AudioSentence.position`).
        public var position: Int
        public var start: Double
        public var end: Double
        /// One line of text: what character indices in lookups count in.
        public var text: String

        public init(position: Int, start: Double, end: Double, text: String) {
            self.position = position
            self.start = start
            self.end = end
            self.text = text
        }
    }

    /// The episode key ("<item>/<episode>", or a book's "<item>").
    public var key: String
    /// Kaku's fingerprint of the transcript: a new one replaces the old.
    public var fingerprint: String
    public var lines: [Line]

    public init(key: String, fingerprint: String, lines: [Line]) {
        self.key = key
        self.fingerprint = fingerprint
        self.lines = lines
    }

    /// What a transcript is known by in `WatchNowPlaying.transcript`.
    public var id: String { Self.id(key: key, fingerprint: fingerprint) }

    public static func id(key: String, fingerprint: String) -> String { "\(key)#\(fingerprint)" }

    /// The line playing at `time` (as the phone's player follows it).
    public func index(at time: Double) -> Int? {
        LineFollow.index(at: time, in: lines, start: \.start)
    }

    /// Lines from `from` on, as many as fit `maxBytes` of JSON (a message holds 64 KB; this leaves
    /// room for the rest of the reply). At least one line, so it always moves on.
    public func part(from: Int, maxBytes: Int = 40_000) -> WatchTranscriptPart {
        var lines: [Line] = []
        var bytes = 0
        for line in self.lines.dropFirst(from) {
            // The line's text plus its numbers and keys.
            let size = line.text.utf8.count + 64
            if !lines.isEmpty, bytes + size > maxBytes { break }
            lines.append(line)
            bytes += size
        }
        return WatchTranscriptPart(key: key, fingerprint: fingerprint, from: from, total: self.lines.count, lines: lines)
    }

    public func encoded() throws -> Data { try JSONEncoder().encode(self) }

    public static func decoded(_ data: Data) throws -> WatchTranscript { try JSONDecoder().decode(Self.self, from: data) }
}

/// Some of a transcript's lines, in reply to `WatchCommand.transcriptPart`.
public struct WatchTranscriptPart: Codable, Equatable, Sendable {
    public var key: String
    public var fingerprint: String
    /// The index of its first line.
    public var from: Int
    /// How many lines the whole transcript has.
    public var total: Int
    public var lines: [WatchTranscript.Line]

    public init(key: String, fingerprint: String, from: Int, total: Int, lines: [WatchTranscript.Line]) {
        self.key = key
        self.fingerprint = fingerprint
        self.from = from
        self.total = total
        self.lines = lines
    }

    public var id: String { WatchTranscript.id(key: key, fingerprint: fingerprint) }
    /// Where the next part starts; nil after the last.
    public var next: Int? { from + lines.count < total ? from + lines.count : nil }
}

/// A transcript coming in parts: whole once the last part is added.
public struct WatchTranscriptAssembly: Equatable, Sendable {
    public let id: String
    public private(set) var lines: [WatchTranscript.Line] = []

    public init(id: String) {
        self.id = id
    }

    /// Where the next part should start.
    public var next: Int { lines.count }

    /// Adds a part in order; returns the transcript when it was the last. A part of another
    /// transcript, or out of order, is ignored.
    public mutating func add(_ part: WatchTranscriptPart) -> WatchTranscript? {
        guard part.id == id, part.from == lines.count else { return nil }
        lines += part.lines
        return part.next == nil ? WatchTranscript(key: part.key, fingerprint: part.fingerprint, lines: lines) : nil
    }
}

/// Which line goes with a playback time: the last one started by then (it stays current through
/// the pause after it). Shared by Kiku's player and Live Text so both follow the same way.
public enum LineFollow {
    public static func index<Line>(at time: Double, in lines: [Line], start: (Line) -> Double) -> Int? {
        var low = 0
        var high = lines.count
        while low < high {
            let middle = (low + high) / 2
            if start(lines[middle]) <= time + 0.05 {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low == 0 ? nil : low - 1
    }
}

/// A word looked up from the watch: what the phone's popup header shows, in brief.
public struct WatchLookup: Codable, Equatable, Sendable {
    /// The matched characters in the line (character offsets, not UTF-16).
    public var start: Int
    public var length: Int
    public var expression: String
    public var reading: String
    /// The first meaning, as the popup's compact summary has it.
    public var meaning: String?
    /// The first frequency, as its dictionary shows it ("1520", "13390㋕").
    public var frequency: String?
    /// "Looked up N times", counting this one; nil when lookup counts are off.
    public var lookupCount: Int?
    /// Already in the mining deck (or queued for it).
    public var isMined: Bool

    public init(start: Int, length: Int, expression: String, reading: String, meaning: String? = nil,
                frequency: String? = nil, lookupCount: Int? = nil, isMined: Bool = false) {
        self.start = start
        self.length = length
        self.expression = expression
        self.reading = reading
        self.meaning = meaning
        self.frequency = frequency
        self.lookupCount = lookupCount
        self.isMined = isMined
    }

    public var range: Range<Int> { start..<(start + max(length, 1)) }
}

/// The transcripts the watch keeps on disk: one for each item on it (milestone 5), and the last
/// few others, newest first.
public struct WatchTranscriptStore: Sendable {
    public static let kept = 5
    let folder: URL

    public init(folder: URL) {
        self.folder = folder
    }

    /// Saves it; `keeping` (the keys of what's on the watch) are never pruned.
    public func save(_ transcript: WatchTranscript, keeping: Set<String> = []) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // One file per episode: a newer transcript of it replaces the older.
        try transcript.encoded().write(to: file(for: transcript.key), options: .atomic)
        prune(keeping: keeping)
    }

    /// Drops all but the items' transcripts and the last few others.
    public func prune(keeping: Set<String>) {
        let kept = Set(keeping.map { file(for: $0).lastPathComponent })
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let others = files.filter { !kept.contains($0.lastPathComponent) }.sorted { modified($0) > modified($1) }
        for old in others.dropFirst(Self.kept) { try? FileManager.default.removeItem(at: old) }
    }

    /// The transcript with this id (key and fingerprint), if it's here.
    public func load(id: String) -> WatchTranscript? {
        guard let key = id.split(separator: "#", maxSplits: 1).first,
              let data = try? Data(contentsOf: file(for: String(key))),
              let transcript = try? WatchTranscript.decoded(data), transcript.id == id else { return nil }
        return transcript
    }

    private func file(for key: String) -> URL {
        folder.appending(path: key.replacingOccurrences(of: "/", with: "_") + ".json")
    }

    private func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
}
