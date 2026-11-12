import AVFoundation
import Foundation
import Lookup

/// Cutting a line's audio from a local file (Kiku's cards, Yomu's read-along cards). AAC in an
/// .m4a, the same format as Miru's clips. AVFoundation can't cut from a stream (-11838).
nonisolated public enum AudioClips {
    /// Before and after the line, as on Miru's cards.
    public static let leadIn = 0.15
    public static let tail = 0.35

    public static func cut(_ url: URL, from start: Double, to end: Double, into output: URL) async throws {
        let asset = AVURLAsset(url: url)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw CocoaError(.featureUnsupported)
        }
        export.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                       end: CMTime(seconds: end, preferredTimescale: 600))
        try await export.export(to: output, as: .m4a)
    }

    /// The line from `start` to `end` (padded) as card audio, or nil when it couldn't be cut.
    public static func sentenceAudio(file: URL, start: Double, end: Double) async -> SentenceAudio? {
        let output = URL.temporaryDirectory.appending(path: "clip-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: output) }
        guard (try? await cut(file, from: max(start - leadIn, 0), to: end + tail, into: output)) != nil,
              let data = try? Data(contentsOf: output), !data.isEmpty else { return nil }
        return SentenceAudio(data: data, fileExtension: "m4a")
    }
}
