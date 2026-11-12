import AVFoundation
import Foundation
@testable import Kiku
import Testing

@MainActor @Suite struct AudioClipTests {
    func duration(_ file: URL) async throws -> Double {
        try await AVURLAsset(url: file).load(.duration).seconds
    }

    @Test func cutsALineFromALocalFile() async throws {
        let source = URL.temporaryDirectory.appending(path: "clip-source-\(UUID().uuidString).caf")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
        let file = try AVAudioFile(forWriting: source, settings: format.settings)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000 * 20))
        buffer.frameLength = buffer.frameCapacity
        try file.write(from: buffer)
        let output = URL.temporaryDirectory.appending(path: "clip-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: output); try? FileManager.default.removeItem(at: source) }
        try await AudioMiningContext.cut(source, from: 4.85, to: 8.35, into: output)
        #expect(abs(try await duration(output) - 3.5) < 0.15)
    }

    /// A streamed episode is fetched once to a temporary file, then cut there.
    @Test func streamedEpisodeIsCutFromATemporaryCopy() async throws {
        let source = URL.temporaryDirectory.appending(path: "clip-source-\(UUID().uuidString).caf")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
        let file = try AVAudioFile(forWriting: source, settings: format.settings)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000 * 10))
        buffer.frameLength = buffer.frameCapacity
        try file.write(from: buffer)
        let context = AudioMiningContext(localAudio: { source }, coverRequest: nil, start: 2, end: 4, miscInfo: "Show — Ep · 0:02")
        let media = await context.cardMedia()
        #expect(media.audio?.fileExtension == "m4a" && (media.audio?.data.count ?? 0) > 0 && media.problems.isEmpty)
        let missing = await AudioMiningContext(localAudio: { nil }, coverRequest: nil, start: 2, end: 4, miscInfo: "x").cardMedia()
        #expect(missing.audio == nil && missing.problems.count == 1)
        try? FileManager.default.removeItem(at: source)
    }
}
