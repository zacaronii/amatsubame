import Foundation
import ImageIO
import JellyfinKit
import Observation
import PlayerKit

/// The picture for the scrub preview: the server's trickplay thumbnails when it made them,
/// otherwise a frame grabbed from the video (the download or the stream) by `MediaClipper`.
/// Grabs wait until the finger rests briefly, run one at a time, and are kept in memory.
@MainActor @Observable
final class ScrubThumbnails {
    enum Source {
        /// Thumbnail sheets from Jellyfin.
        case trickplay(JellyfinClient, itemId: String, mediaSourceId: String, info: JellyfinTrickplayInfo)
        /// Frames from the video itself.
        case video(location: String, headers: [String: String])
    }

    /// The latest picture (it stays up until a newer one arrives).
    private(set) var image: CGImage?

    @ObservationIgnored private let source: Source
    @ObservationIgnored private var target: Double?
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var frames: [Int: CGImage] = [:]
    @ObservationIgnored private var sheets: [Int: CGImage] = [:]
    @ObservationIgnored private lazy var folder = URL.temporaryDirectory.appending(path: "scrub-\(UUID().uuidString)")
    /// Frames are shared within this many seconds.
    static let bucket = 2.0
    static let rest: Duration = .milliseconds(120)
    static let frameWidth = 360

    init(source: Source) {
        self.source = source
    }

    /// Shows the picture for `time` as soon as it's known.
    func request(_ time: Double) {
        target = time
        if let cached = cached(time) {
            image = cached
            return
        }
        guard worker == nil else { return }
        worker = Task { await run() }
    }

    /// Scrubbing ended: forget the target (the cache stays for the next scrub).
    func stop() {
        target = nil
    }

    /// The player closed: drop everything, including the grabbed files.
    func close() {
        worker?.cancel()
        target = nil
        frames = [:]
        sheets = [:]
        try? FileManager.default.removeItem(at: folder)
    }

    private func key(_ time: Double) -> Int { Int((time / Self.bucket).rounded()) }

    private func cached(_ time: Double) -> CGImage? {
        switch source {
        case .trickplay(_, _, _, let info):
            guard let cell = info.cell(at: time), let sheet = sheets[cell.sheet] else { return nil }
            return sheet.cropping(to: CGRect(x: cell.x, y: cell.y, width: cell.width, height: cell.height))
        case .video:
            return frames[key(time)]
        }
    }

    private func run() async {
        defer { worker = nil }
        while !Task.isCancelled {
            try? await Task.sleep(for: Self.rest)
            guard let time = target, !Task.isCancelled else { return }
            if let cached = cached(time) {
                image = cached
            } else if let fresh = await load(time) {
                image = fresh
            }
            // Done unless the finger moved on to a part not loaded yet.
            guard let next = target, cached(next) == nil, key(next) != key(time) else { return }
        }
    }

    private func load(_ time: Double) async -> CGImage? {
        switch source {
        case .trickplay(let client, let itemId, let mediaSourceId, let info):
            guard let cell = info.cell(at: time) else { return nil }
            let request = client.trickplaySheetRequest(itemId: itemId, mediaSourceId: mediaSourceId, width: info.width, sheet: cell.sheet)
            guard let (data, _) = try? await URLSession.shared.data(for: request), let sheet = Self.decode(data) else { return nil }
            sheets[cell.sheet] = sheet
            return cached(time)
        case .video(let location, let headers):
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let bucketTime = Double(key(time)) * Self.bucket
            let file = folder.appending(path: "\(key(time)).jpg")
            guard (try? await MediaClipper.frame(from: location, headers: headers, at: bucketTime, maxWidth: Self.frameWidth, to: file)) != nil,
                  let data = try? Data(contentsOf: file), let frame = Self.decode(data) else { return nil }
            try? FileManager.default.removeItem(at: file)
            if frames.count > 200 { frames = [:] }
            frames[key(time)] = frame
            return frame
        }
    }

    private static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
