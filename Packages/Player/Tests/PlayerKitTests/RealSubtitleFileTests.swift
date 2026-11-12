import ImageIO
import Foundation
@testable import PlayerKit
import Testing

/// Real subtitle files (e.g. from Jimaku), outside the repo: `REAL_SUBTITLE_FILES="<path>|<path>"`.
@Suite struct RealSubtitleFileTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["REAL_SUBTITLE_FILES"] != nil))
    func realFilesParse() throws {
        for path in (ProcessInfo.processInfo.environment["REAL_SUBTITLE_FILES"] ?? "").split(separator: "|").map(String.init) {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let text = try #require(SubtitleFile.decode(data), "\(path) decodes")
            let format = try #require(SubtitleFile.format(fileName: path, text: text))
            let track = SubtitleFile.track(text, format: format)
            let japanese = track.cues.filter { $0.text.contains(/\p{Script=Hiragana}|\p{Script=Katakana}|\p{Script=Han}/) }
            print("\((path as NSString).lastPathComponent): \(format) \(track.cues.count) cues, \(japanese.count) Japanese; e.g. \(track.cues.dropFirst(20).first?.text.replacingOccurrences(of: "\n", with: " / ") ?? "-")")
            #expect(track.cues.count > 100, "\(path)")
            #expect(Double(japanese.count) > Double(track.cues.count) * 0.8, "\(path) is mostly Japanese")
            #expect(!track.cues.contains { $0.text.contains("{") || $0.text.contains("\\N") }, "\(path) has no leftover tags")
        }
    }

    /// `REAL_SYNC_PAIRS="<subtitle>><reference>|…"`: syncs each subtitle to its reference
    /// (e.g. a Jimaku file to the episode's English track) and reports the parts. Each is
    /// also shifted by known amounts (and split) to check they're found.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["REAL_SYNC_PAIRS"] != nil))
    func realFilesSync() throws {
        for pair in (ProcessInfo.processInfo.environment["REAL_SYNC_PAIRS"] ?? "").split(separator: "|") {
            let paths = pair.split(separator: ">").map(String.init)
            let subtitle = try Self.spans(paths[0]), reference = try Self.spans(paths[1])
            let names = paths.map { ($0 as NSString).lastPathComponent }.joined(separator: " → ")
            let start = Date()
            let options = SubtitleSync.Options(splitPenalty: Double(ProcessInfo.processInfo.environment["REAL_SYNC_PENALTY"] ?? "") ?? 20)
            let result = try #require(SubtitleSync.align(subtitle, to: reference, options: options), "\(names)")
            let parts = result.parts.map { String(format: "%@%+.2f s", $0.from.isFinite ? String(format: "from %.0f s: ", $0.from) : "", $0.shift) }
            print("\(names): \(parts.joined(separator: ", ")), match \(Int(result.match * 100))% in \(String(format: "%.2f", Date().timeIntervalSince(start))) s")
            // Known moves on top of whatever it found.
            let moved = subtitle.map { SubtitleSync.Span(start: $0.start - 7.3, end: $0.end - 7.3) }
            let found = try #require(SubtitleSync.align(moved, to: reference, options: options))
            print("  moved 7.3 s earlier: \(found.parts.map { String(format: "%+.2f", $0.shift) })")
            #expect(abs(found.shift(at: 300) - (result.shift(at: 300) + 7.3)) < 0.1, "\(names)")
            let split = subtitle.map { $0.start < 700 ? $0 : SubtitleSync.Span(start: $0.start + 12, end: $0.end + 12) }
            let splitFound = try #require(SubtitleSync.align(split, to: reference, options: options))
            print("  +12 s after 700 s: \(splitFound.parts.map { String(format: "%@%+.2f", $0.from.isFinite ? String(format: "%.0f:", $0.from) : "", $0.shift) })")
            // Files that only partly match (a different cut) may not show a split this small.
            guard result.match >= 0.75 else { continue }
            #expect(abs(splitFound.shift(at: 300) - result.shift(at: 300)) < 0.1 && abs(splitFound.shift(at: 1000) - (result.shift(at: 1000) - 12)) < 0.1, "\(names)")
        }
    }

    /// `REAL_SYNC_AUDIO=<file or URL>` (with `REAL_SYNC_AUDIO_AUTH=<Authorization header>` for
    /// a server) and `REAL_SYNC_AUDIO_SUBTITLES="<path>|…"`: finds the speech in the audio and
    /// syncs each subtitle to it, reporting the time taken and the parts.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["REAL_SYNC_AUDIO"] != nil))
    func realAudioSync() async throws {
        let env = ProcessInfo.processInfo.environment
        let location = try #require(env["REAL_SYNC_AUDIO"])
        let headers = env["REAL_SYNC_AUDIO_AUTH"].map { ["Authorization": $0] } ?? [:]
        let modes: [Int32] = (env["REAL_SYNC_VAD_MODES"] ?? "\(SpeechDetector.defaultMode)").split(separator: ",").compactMap { Int32($0) }
        let penalties = (env["REAL_SYNC_PENALTIES"] ?? "20").split(separator: ",").compactMap { Double($0) }
        let start = Date()
        let all = try await MediaClipper.speech(from: location, headers: headers, modes: modes)
        print(String(format: "speech found in %.1f s", Date().timeIntervalSince(start)))
        for (mode, speech) in zip(modes, all) {
            let talking = speech.reduce(0) { $0 + $1.end - $1.start }
            print(String(format: "mode %d: %d spans, %.0f s of %.0f s", mode, speech.count, talking, speech.last?.end ?? 0))
            #expect(speech.count > 50)
            for penalty in penalties {
                for path in (env["REAL_SYNC_AUDIO_SUBTITLES"] ?? "").split(separator: "|").map(String.init) {
                    let subtitle = try Self.spans(path)
                    let result = try #require(SubtitleSync.align(subtitle, to: speech, options: .init(splitPenalty: penalty)))
                    let parts = result.parts.map { String(format: "%@%+.2f s", $0.from.isFinite ? String(format: "from %.0f s: ", $0.from) : "", $0.shift) }
                    print("  penalty \(penalty) \((path as NSString).lastPathComponent): \(parts.joined(separator: ", ")), match \(Int(result.match * 100))%")
                }
            }
        }
    }

    static func spans(_ path: String) throws -> [SubtitleSync.Span] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let text = try #require(SubtitleFile.decode(data))
        let format = try #require(SubtitleFile.format(fileName: path, text: text))
        return SubtitleSync.spans(SubtitleFile.track(text, format: format))
    }
}

/// Card media from a real stream or file: `REAL_CLIP_URL=<url or path>`, with
/// `REAL_CLIP_AUTH=<Authorization header>` for a Jellyfin stream and `REAL_CLIP_AT=<seconds>`.
@Suite struct RealClipTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["REAL_CLIP_URL"] != nil))
    func clipsAudioAndAFrame() async throws {
        let env = ProcessInfo.processInfo.environment
        let url = try #require(env["REAL_CLIP_URL"])
        let headers = env["REAL_CLIP_AUTH"].map { ["Authorization": $0] } ?? [:]
        let time = env["REAL_CLIP_AT"].flatMap(Double.init) ?? 60
        let folder = URL.temporaryDirectory
        let size = { (file: URL) in (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
        let started = Date()
        let result = try await MediaClipper.card(from: url, headers: headers, frameAt: time + 1, frameTo: folder.appending(path: "real-frame.jpg"),
                                                 start: time, end: time + 3, audioTo: folder.appending(path: "real-clip.m4a"))
        let frame = try result.frame.get(), audio = try result.audio.get()
        print("frame \(size(frame)) B, audio \(size(audio)) B in \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
        #expect(size(frame) > 1000 && size(audio) > 1000)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["REAL_CLIP_URL"] != nil))
    func animatedPicture() async throws {
        let env = ProcessInfo.processInfo.environment
        let url = try #require(env["REAL_CLIP_URL"])
        let headers = env["REAL_CLIP_AUTH"].map { ["Authorization": $0] } ?? [:]
        let time = env["REAL_CLIP_AT"].flatMap(Double.init) ?? 60
        let folder = URL.temporaryDirectory
        let started = Date()
        let result = try await MediaClipper.card(from: url, headers: headers, frameAt: time, frameTo: folder.appending(path: "real-line.gif"),
                                                 animate: time...(time + 4), start: time, end: time + 4,
                                                 audioTo: folder.appending(path: "real-line.m4a"))
        let gif = try result.frame.get()
        _ = try result.audio.get()
        let data = try Data(contentsOf: gif)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        print("gif \(data.count) B, \(CGImageSourceGetCount(source)) frames, \(image.width)×\(image.height) in \(String(format: "%.1f", Date().timeIntervalSince(started))) s at \(gif.path)")
        #expect(CGImageSourceGetCount(source) > 20)
        #expect(data.count <= MediaClipper.animationMaxBytes)
        #expect(image.width <= 480)
    }
}
