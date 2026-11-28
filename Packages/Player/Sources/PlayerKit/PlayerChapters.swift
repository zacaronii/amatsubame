import Foundation

/// A video's chapters for the scrubber's marks and previous/next chapter: from Jellyfin's item,
/// or the file's own (mpv) for a download or a local file.
public struct PlayerChapters: Equatable, Sendable {
    public struct Chapter: Equatable, Sendable {
        public var start: Double
        public var name: String?
    }

    /// In order, one per start (several at the same start keep the last: a prologue and the
    /// opening both at 0 are the opening), within the video.
    public let chapters: [Chapter]

    /// A previous-chapter press this far into a chapter goes to its start; sooner, to the one
    /// before (as mpv and other players do).
    public static let restartWindow: Double = 3

    public init(_ chapters: [(start: Double, name: String?)], duration: Double?) {
        var byStart: [Chapter] = []
        for chapter in chapters.sorted(by: { $0.start < $1.start }) {
            let start = max(chapter.start, 0)
            if let duration, duration > 0, start >= duration { continue }
            if let last = byStart.last, abs(last.start - start) < 0.5 {
                byStart[byStart.count - 1] = Chapter(start: last.start, name: chapter.name)
            } else {
                byStart.append(Chapter(start: start, name: chapter.name))
            }
        }
        self.chapters = byStart
    }

    /// Marks and chapter moves only for a video with at least two.
    public var isEmpty: Bool { chapters.count < 2 }

    /// The chapter playing at `time`.
    public func index(at time: Double) -> Int? {
        guard !isEmpty else { return nil }
        return chapters.lastIndex { $0.start <= time + 0.05 } ?? 0
    }

    public func name(at time: Double) -> String? {
        index(at: time).flatMap { chapters[$0].name }
    }

    /// Where previous chapter goes from `time`: this chapter's start, or the one before when
    /// it only just began.
    public func previousStart(from time: Double) -> Double? {
        guard let index = index(at: time) else { return nil }
        if time - chapters[index].start > Self.restartWindow { return chapters[index].start }
        return index > 0 ? chapters[index - 1].start : chapters[0].start
    }

    /// Where next chapter goes from `time`; nil in the last.
    public func nextStart(from time: Double) -> Double? {
        guard let index = index(at: time), index + 1 < chapters.count else { return nil }
        return chapters[index + 1].start
    }

    /// Where the marks go on a scrubber, as fractions of the video (the first, at 0, has none).
    public func marks(duration: Double) -> [Double] {
        guard !isEmpty, duration > 0 else { return [] }
        return chapters.map(\.start).filter { $0 > 0 }.map { $0 / duration }
    }
}
