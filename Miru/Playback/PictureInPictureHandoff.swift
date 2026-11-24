import Foundation

/// What picture in picture can play: the file itself (Jellyfin's direct stream, or a download
/// AVPlayer can open), or Jellyfin's HLS transcode (with the Japanese track in its playlist).
struct PiPSource: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case direct, transcode }
    var kind: Kind
    var url: URL
    var headers: [String: String] = [:]
    /// A transcode's play session, to stop it when picture in picture ends.
    var playSessionId: String?
}

/// The player picture in picture shows (AVPlayer in the app, a fake in tests).
@MainActor protocol PiPPlayer: AnyObject {
    /// Loads `source` and seeks to `time`. True once it's ready to play; false if it failed.
    func prepare(_ source: PiPSource, at time: Double) async -> Bool
    func play(rate: Float)
    func pause()
    var currentTime: Double { get }
    var isPlaying: Bool { get }
    /// Lets go of the item (after a failure, or when picture in picture ends).
    func reset()
}

/// Hands playback from mpv to the picture-in-picture player and back. Tries the sources in
/// order (the direct stream first, when the file suits AVPlayer, then the transcode) and takes
/// the first that's ready; a failure goes straight to the next. Gives up when all fail or the
/// whole start takes longer than `timeout` (mpv then plays on). A transcode started and not
/// used, or used and finished with, is stopped.
@MainActor
final class PictureInPictureHandoff {
    typealias SourceMaker = @MainActor () async -> PiPSource?

    let player: PiPPlayer
    let timeout: Duration
    private let stopTranscode: (String) -> Void
    private(set) var active: PiPSource?

    init(player: PiPPlayer, timeout: Duration = .seconds(8), stopTranscode: @escaping (String) -> Void) {
        self.player = player
        self.timeout = timeout
        self.stopTranscode = stopTranscode
    }

    /// The source playing, or nil to stay with mpv.
    func start(at time: Double, sources: [SourceMaker]) async -> PiPSource? {
        let player = player
        let attempt = Task { @MainActor () -> PiPSource? in
            for make in sources {
                guard !Task.isCancelled, let source = await make() else { continue }
                if Task.isCancelled {
                    self.release(source)
                    return nil
                }
                if await player.prepare(source, at: time), !Task.isCancelled { return source }
                // Failed (or too late): on to the next, letting this one go.
                player.reset()
                self.release(source)
            }
            return nil
        }
        let timer = Task { @MainActor in
            try? await Task.sleep(for: timeout)
            if !Task.isCancelled { attempt.cancel() }
        }
        let source = await attempt.value
        timer.cancel()
        guard let source, !attempt.isCancelled else {
            if let source { release(source) }
            player.reset()
            return nil
        }
        active = source
        return source
    }

    /// Picture in picture ends: where it got to, and whether it was playing (mpv picks up from
    /// there). The player lets go and a transcode is stopped.
    func finish() -> (time: Double, wasPlaying: Bool) {
        let result = (player.currentTime, player.isPlaying)
        player.pause()
        player.reset()
        if let active { release(active) }
        active = nil
        return result
    }

    private func release(_ source: PiPSource) {
        if source.kind == .transcode, let id = source.playSessionId { stopTranscode(id) }
    }

    /// Whether a file in `container` with these codecs opens in AVPlayer as it is.
    static func playsDirectly(container: String?, videoCodec: String?, audioCodec: String?) -> Bool {
        let containers: Set<String> = ["mp4", "m4v", "mov"]
        let video: Set<String> = ["h264", "hevc", "h265"]
        let audio: Set<String> = ["aac", "mp3", "ac3", "eac3", "alac"]
        guard let container = container?.lowercased().split(separator: ",").map(String.init),
              container.contains(where: containers.contains) else { return false }
        guard let videoCodec = videoCodec?.lowercased(), video.contains(videoCodec) else { return false }
        return audioCodec.map { audio.contains($0.lowercased()) } ?? true
    }
}
