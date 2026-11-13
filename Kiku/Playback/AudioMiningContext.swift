import AVFoundation
import AppCommon
import Foundation
import Lookup

/// Card media for a transcript line: its audio (with Miru's padding), cut from the downloaded
/// file (works offline), by Kaku from the stream, or from a temporary copy of the stream; and
/// the episode's artwork.
struct AudioMiningContext: MiningContext {
    /// The episode's audio as a local file: AVFoundation can't cut from a stream.
    var localAudio: @Sendable () async -> URL?
    /// Kaku's clip of a streamed episode, tried first (nil for downloads, and when it fails).
    var remoteClip: (@Sendable (Double, Double) async -> Data?)? = nil
    var coverRequest: URLRequest?
    var start: Double
    var end: Double
    var miscInfo: String
    var seriesKey: String?
    var seriesTitle: String?

    /// Before and after the line, as on Miru's cards.
    static let leadIn = 0.15
    static let tail = 0.35

    func pictureData() async -> Data? {
        guard let coverRequest else { return nil }
        // Offline, the cover cached when the page showed it.
        return try? await CoverLoader.data(for: coverRequest)
    }

    func sentenceAudio() async -> SentenceAudio? {
        if let remoteClip, let data = await remoteClip(max(start - Self.leadIn, 0), end + Self.tail), !data.isEmpty {
            return SentenceAudio(data: data, fileExtension: "m4a")
        }
        let file = URL.temporaryDirectory.appending(path: "clip-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: file) }
        guard let audio = await localAudio(),
              (try? await Self.cut(audio, from: max(start - Self.leadIn, 0), to: end + Self.tail, into: file)) != nil,
              let data = try? Data(contentsOf: file), !data.isEmpty else { return nil }
        return SentenceAudio(data: data, fileExtension: "m4a")
    }

    func cardMedia() async -> CardMedia {
        async let picture = pictureData()
        async let audio = sentenceAudio()
        let (cover, clip) = await (picture, audio)
        return CardMedia(picture: cover, audio: clip, problems: clip == nil ? ["No sentence audio: the clip couldn't be cut."] : [])
    }

    /// AAC in an .m4a: the same format as Miru's clips (shared with Yomu's read-along).
    static func cut(_ url: URL, from start: Double, to end: Double, into output: URL) async throws {
        try await AudioClips.cut(url, from: start, to: end, into: output)
    }
}
