import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import Libavcodec
import Libavformat
import Libavutil
import Libswresample
import Libswscale
import UniformTypeIdentifiers

/// Makes card media from any stretch of a video without the on-screen player, using the
/// FFmpeg libraries bundled with MPVKit (libmpv itself refuses encoding mode). It reads the
/// same stream as the player, so lines picked from a transcript can be mined too.
/// - Audio: decoded with FFmpeg, written as AAC (.m4a) by AVAudioFile.
/// - Picture: one decoded frame, written as JPEG by ImageIO, or the line as an animated GIF.
public enum MediaClipper {
    public enum ClipError: Error, LocalizedError, Equatable {
        case open(String)
        case noStream(String)
        case failed(String)
        case empty

        public var errorDescription: String? {
            switch self {
            case .open(let detail): "Couldn't open the video for the clip (\(detail))."
            case .noStream(let kind): "The video has no \(kind) to clip."
            case .failed(let detail): "Making the clip failed: \(detail)"
            case .empty: "The clip came out empty."
            }
        }

        public init(_ error: any Error) {
            self = error as? ClipError ?? .failed(error.localizedDescription)
        }
    }

    /// Card media for one line from a single open of the source: a frame at `frameTime` and the
    /// audio from `start` to `end`. Opening is the slow part on a stream (a release with embedded
    /// subtitle fonts reads tens of MB first), so both come from the same input. Each part fails
    /// on its own. With `animate`, the picture is that stretch as an animated GIF instead.
    public static func card(from location: String, headers: [String: String] = [:], frameAt frameTime: Double,
                            maxWidth: Int = 1280, frameTo frameOutput: URL, animate: ClosedRange<Double>? = nil,
                            start: Double, end: Double, audioTrack: Int? = nil, audioTo audioOutput: URL) async throws
        -> (frame: Result<URL, ClipError>, audio: Result<URL, ClipError>) {
        try await Task.detached(priority: .userInitiated) {
            let input = try Input(location, headers: headers)
            let frame: Result<URL, ClipError>, audio: Result<URL, ClipError>
            do {
                if let animate {
                    try grabAnimation(input: input, start: animate.lowerBound, end: animate.upperBound, output: frameOutput)
                } else {
                    try grabFrame(input: input, time: frameTime, maxWidth: maxWidth, output: frameOutput)
                }
                frame = .success(frameOutput)
            } catch {
                frame = .failure(ClipError(error))
            }
            do {
                try clipAudio(input: input, start: start, end: end, streamIndex: audioTrack, output: audioOutput)
                audio = .success(audioOutput)
            } catch {
                audio = .failure(ClipError(error))
            }
            return (frame, audio)
        }.value
    }

    /// The audio from `start` to `end` seconds. `audioTrack` is the stream's index in the
    /// file (FFmpeg numbering, as Jellyfin reports it); nil picks the default audio.
    public static func audio(from location: String, headers: [String: String] = [:], start: Double, end: Double,
                             audioTrack: Int? = nil, to output: URL) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            try clipAudio(location: location, headers: headers, start: start, end: end, streamIndex: audioTrack, output: output)
            return output
        }.value
    }

    /// The frame at `time` seconds, scaled to at most `maxWidth` pixels wide.
    public static func frame(from location: String, headers: [String: String] = [:], at time: Double,
                             maxWidth: Int = 1280, to output: URL) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            try grabFrame(location: location, headers: headers, time: time, maxWidth: maxWidth, output: output)
            return output
        }.value
    }

    /// Where people speak in the audio (for syncing subtitles), from the start to the end of
    /// the file or stream. `progress` gets the seconds decoded so far now and then.
    public static func speech(from location: String, headers: [String: String] = [:], audioTrack: Int? = nil,
                              modes: [Int32] = [SpeechDetector.defaultMode],
                              progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> [[SubtitleSync.Span]] {
        try await Task.detached(priority: .userInitiated) {
            try detectSpeech(location: location, headers: headers, streamIndex: audioTrack, modes: modes, progress: progress)
        }.value
    }

    public static func speech(from location: String, headers: [String: String] = [:], audioTrack: Int? = nil,
                              progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> [SubtitleSync.Span] {
        try await speech(from: location, headers: headers, audioTrack: audioTrack, modes: [SpeechDetector.defaultMode],
                         progress: progress)[0]
    }

    // MARK: FFmpeg plumbing

    /// The bundled root certificates for HTTPS streams.
    static let certificateRoots = Bundle.module.url(forResource: "cacert", withExtension: "pem")?.path(percentEncoded: false)

    private static let errorAgain = -EAGAIN
    private static let errorEOF: Int32 = -541_478_725 // AVERROR_EOF ('EOF ' tag)

    fileprivate static func describe(_ code: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        av_strerror(code, &buffer, buffer.count)
        return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    /// The build number in x264's "x264 - core <build>" note, if `bytes` hold one.
    static func x264Build(in bytes: UnsafeBufferPointer<UInt8>) -> Int? {
        let marker = Array("x264 - core ".utf8)
        guard bytes.count > marker.count else { return nil }
        for start in 0...(bytes.count - marker.count) where bytes[start] == marker[0] {
            guard bytes[start..<start + marker.count].elementsEqual(marker) else { continue }
            let digits = bytes[(start + marker.count)...].prefix { $0 >= 48 && $0 <= 57 }
            return digits.isEmpty ? nil : Int(String(decoding: digits, as: UTF8.self))
        }
        return nil
    }

    /// An open input, closed on deinit.
    private final class Input {
        var context: UnsafeMutablePointer<AVFormatContext>?

        init(_ location: String, headers: [String: String]) throws {
            var options: OpaquePointer?
            if !headers.isEmpty {
                let lines = headers.map { "\($0.key): \($0.value)\r\n" }.joined()
                av_dict_set(&options, "headers", lines, 0)
            }
            av_dict_set(&options, "reconnect", "1", 0)
            // MPVKit's iOS FFmpeg has no certificate store of its own, so HTTPS opens failed
            // verification on iPhone and iPad; it verifies against Mozilla's roots instead
            // (curl's cacert.pem, see Resources/README.md).
            if let roots = MediaClipper.certificateRoots { av_dict_set(&options, "ca_file", roots, 0) }
            defer { av_dict_free(&options) }
            let result = avformat_open_input(&context, location, nil, &options)
            guard result >= 0 else { throw ClipError.open(MediaClipper.describe(result)) }
            avformat_find_stream_info(context, nil)
        }

        deinit { avformat_close_input(&context) }

        func stream(_ type: Libavutil.AVMediaType, preferred: Int?) -> Int32? {
            if let preferred, let context, preferred >= 0, preferred < Int(context.pointee.nb_streams),
               context.pointee.streams[preferred]?.pointee.codecpar.pointee.codec_type == type {
                return Int32(preferred)
            }
            let best = av_find_best_stream(context, type, -1, -1, nil, 0)
            return best >= 0 ? best : nil
        }

        /// The x264 version that encoded `stream`, from the note x264 puts in its first frame.
        /// FFmpeg undoes old x264 bugs (4:4:4 video before build 151 decodes as coloured
        /// blocks otherwise) only once it has seen that note, and a seek skips it, so read it
        /// first: call before seeking, while the input is still at the start.
        func x264Build(stream: Int32) -> Int? {
            var packet = av_packet_alloc()
            defer { av_packet_free(&packet) }
            for _ in 0..<200 {
                guard av_read_frame(context, packet) >= 0, let packet else { return nil }
                defer { av_packet_unref(packet) }
                guard packet.pointee.stream_index == stream else { continue }
                return MediaClipper.x264Build(in: UnsafeBufferPointer(start: packet.pointee.data, count: Int(packet.pointee.size)))
            }
            return nil
        }

        /// Seeks so decoding starts at or before `seconds`. It seeks on the default (video) stream
        /// through the container's index: seeking an audio stream of a streamed MKV read ~14 s of
        /// it, the index takes about one.
        func seek(to seconds: Double) {
            guard let context else { return }
            let target = Int64(seconds * Double(AV_TIME_BASE))
            avformat_seek_file(context, -1, Int64.min, target, target, 0)
        }
    }

    /// A decoder for one stream, freed on deinit.
    private final class Decoder {
        var context: UnsafeMutablePointer<AVCodecContext>?
        let timeBase: AVRational

        /// `x264Build` is the encoder version from the stream's start (see `Input.x264Build`).
        init(input: Input, stream: Int32, x264Build: Int? = nil) throws {
            guard let avStream = input.context?.pointee.streams[Int(stream)],
                  let codec = avcodec_find_decoder(avStream.pointee.codecpar.pointee.codec_id) else {
                throw ClipError.failed("no decoder")
            }
            timeBase = avStream.pointee.time_base
            context = avcodec_alloc_context3(codec)
            avcodec_parameters_to_context(context, avStream.pointee.codecpar)
            var options: OpaquePointer?
            if let x264Build { av_dict_set(&options, "x264_build", String(x264Build), 0) }
            defer { av_dict_free(&options) }
            let result = avcodec_open2(context, codec, &options)
            guard result >= 0 else { throw ClipError.failed(MediaClipper.describe(result)) }
        }

        deinit { avcodec_free_context(&context) }

        func seconds(_ pts: Int64) -> Double {
            Double(pts) * Double(timeBase.num) / Double(timeBase.den)
        }
    }

    /// Feeds `stream`'s packets to `decoder` and hands each decoded frame to `handle`,
    /// which returns false to stop.
    private static func decode(input: Input, stream: Int32, decoder: Decoder,
                               handle: (UnsafeMutablePointer<AVFrame>) throws -> Bool) throws {
        var packet = av_packet_alloc()
        var frame = av_frame_alloc()
        defer {
            av_packet_free(&packet)
            av_frame_free(&frame)
        }
        /// Hands over every frame the decoder has ready; false once `handle` wants no more.
        func drain() throws -> Bool {
            while true {
                let result = avcodec_receive_frame(decoder.context, frame)
                if result == errorAgain || result == errorEOF { return true }
                guard result >= 0, let frame else { return false }
                let keepGoing = try handle(frame)
                av_frame_unref(frame)
                if !keepGoing { return false }
            }
        }
        while av_read_frame(input.context, packet) >= 0 {
            defer { av_packet_unref(packet) }
            guard packet?.pointee.stream_index == stream else { continue }
            guard avcodec_send_packet(decoder.context, packet) >= 0 else { continue }
            guard try drain() else { return }
        }
        // End of the file: flush the frames the decoder is still holding (the last ones, or a
        // decoder that buffers ahead, would otherwise never come out).
        avcodec_send_packet(decoder.context, nil)
        _ = try drain()
    }

    // MARK: Audio

    private static func clipAudio(location: String, headers: [String: String], start: Double, end: Double,
                                  streamIndex: Int?, output: URL) throws {
        try clipAudio(input: try Input(location, headers: headers), start: start, end: end, streamIndex: streamIndex, output: output)
    }

    private static func clipAudio(input: Input, start: Double, end: Double, streamIndex: Int?, output: URL) throws {
        guard let stream = input.stream(AVMEDIA_TYPE_AUDIO, preferred: streamIndex) else { throw ClipError.noStream("audio") }
        let decoder = try Decoder(input: input, stream: stream)
        input.seek(to: start)

        // Everything is converted to 48 kHz stereo float, then written as AAC.
        let sampleRate: Int32 = 48_000
        var resampler: OpaquePointer?
        var outLayout = AVChannelLayout()
        av_channel_layout_default(&outLayout, 2)
        defer {
            swr_free(&resampler)
            av_channel_layout_uninit(&outLayout)
        }
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 2, interleaved: false) else {
            throw ClipError.failed("audio format")
        }
        try? FileManager.default.removeItem(at: output)
        let file = try AVAudioFile(forWriting: output, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: Double(sampleRate), AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        var written = 0

        try decode(input: input, stream: stream, decoder: decoder) { frame in
            let pts = frame.pointee.best_effort_timestamp
            let frameStart = pts == Int64.min ? start : decoder.seconds(pts)
            if frameStart >= end { return false }
            let frameEnd = frameStart + Double(frame.pointee.nb_samples) / Double(frame.pointee.sample_rate)
            if frameEnd <= start { return true }

            if resampler == nil {
                guard swr_alloc_set_opts2(&resampler, &outLayout, AV_SAMPLE_FMT_FLTP, sampleRate,
                                          &frame.pointee.ch_layout, AVSampleFormat(frame.pointee.format), frame.pointee.sample_rate,
                                          0, nil) >= 0, swr_init(resampler) >= 0 else {
                    throw ClipError.failed("resampler")
                }
            }
            let capacity = swr_get_out_samples(resampler, frame.pointee.nb_samples) + 64
            guard capacity > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(capacity)),
                  let channels = buffer.floatChannelData else { return true }
            var outputs: [UnsafeMutablePointer<UInt8>?] = [
                UnsafeMutableRawPointer(channels[0]).assumingMemoryBound(to: UInt8.self),
                UnsafeMutableRawPointer(channels[1]).assumingMemoryBound(to: UInt8.self),
            ]
            let inputs = UnsafeMutableRawPointer(frame.pointee.extended_data).map {
                UnsafePointer($0.assumingMemoryBound(to: UnsafePointer<UInt8>?.self))
            }
            let converted = outputs.withUnsafeMutableBufferPointer { out in
                swr_convert(resampler, out.baseAddress, capacity, inputs, frame.pointee.nb_samples)
            }
            guard converted > 0 else { return true }
            buffer.frameLength = AVAudioFrameCount(converted)

            // Trim the first and last frames to exactly [start, end).
            let skip = max(0, Int((start - frameStart) * Double(sampleRate)))
            let keep = min(Int(converted), Int((end - frameStart) * Double(sampleRate))) - skip
            guard keep > 0 else { return true }
            if skip > 0 || keep < Int(converted) {
                for channel in 0..<2 {
                    let samples = channels[channel]
                    samples.update(from: samples + skip, count: keep)
                }
                buffer.frameLength = AVAudioFrameCount(keep)
            }
            try file.write(from: buffer)
            written += keep
            return true
        }
        guard written > 0 else { throw ClipError.empty }
    }

    // MARK: Speech

    private static func detectSpeech(location: String, headers: [String: String], streamIndex: Int?, modes: [Int32],
                                     progress: (Double) -> Void) throws -> [[SubtitleSync.Span]] {
        let input = try Input(location, headers: headers)
        guard let stream = input.stream(AVMEDIA_TYPE_AUDIO, preferred: streamIndex) else { throw ClipError.noStream("audio") }
        let decoder = try Decoder(input: input, stream: stream)
        let detectors = modes.map { SpeechDetector(mode: $0) }
        let detector = detectors[0]
        let sampleRate = Int32(SpeechDetector.sampleRate)
        var resampler: OpaquePointer?
        var outLayout = AVChannelLayout()
        av_channel_layout_default(&outLayout, 1)
        defer {
            swr_free(&resampler)
            av_channel_layout_uninit(&outLayout)
        }
        var samples = [Int16]()
        var start: Double?
        var reported = 0.0
        try decode(input: input, stream: stream, decoder: decoder) { frame in
            try Task.checkCancellation()
            if start == nil {
                // Keep the file's own clock: silence until the first audio frame.
                let pts = frame.pointee.best_effort_timestamp
                start = pts == Int64.min ? 0 : max(decoder.seconds(pts), 0)
                let lead = Int((start ?? 0) * Double(sampleRate))
                if lead > 0 {
                    let silence = [Int16](repeating: 0, count: lead)
                    silence.withUnsafeBufferPointer { buffer in detectors.forEach { $0.add(buffer) } }
                }
            }
            if resampler == nil {
                guard swr_alloc_set_opts2(&resampler, &outLayout, AV_SAMPLE_FMT_S16, sampleRate,
                                          &frame.pointee.ch_layout, AVSampleFormat(frame.pointee.format), frame.pointee.sample_rate,
                                          0, nil) >= 0, swr_init(resampler) >= 0 else {
                    throw ClipError.failed("resampler")
                }
            }
            let capacity = Int(swr_get_out_samples(resampler, frame.pointee.nb_samples)) + 64
            if samples.count < capacity { samples = [Int16](repeating: 0, count: capacity) }
            let inputs = UnsafeMutableRawPointer(frame.pointee.extended_data).map {
                UnsafePointer($0.assumingMemoryBound(to: UnsafePointer<UInt8>?.self))
            }
            let converted = samples.withUnsafeMutableBytes { raw -> Int32 in
                var outputs: [UnsafeMutablePointer<UInt8>?] = [raw.baseAddress?.assumingMemoryBound(to: UInt8.self)]
                return outputs.withUnsafeMutableBufferPointer { out in
                    swr_convert(resampler, out.baseAddress, Int32(capacity), inputs, frame.pointee.nb_samples)
                }
            }
            if converted > 0 {
                samples.withUnsafeBufferPointer { buffer in
                    detectors.forEach { $0.add(UnsafeBufferPointer(rebasing: buffer[0..<Int(converted)])) }
                }
            }
            if detector.time - reported >= 30 {
                reported = detector.time
                progress(reported)
            }
            return true
        }
        return detectors.map { $0.finish() }
    }

    // MARK: Picture

    private static func grabFrame(location: String, headers: [String: String], time: Double, maxWidth: Int, output: URL) throws {
        try grabFrame(input: try Input(location, headers: headers), time: time, maxWidth: maxWidth, output: output)
    }

    private static func grabFrame(input: Input, time: Double, maxWidth: Int, output: URL) throws {
        guard let stream = input.stream(AVMEDIA_TYPE_VIDEO, preferred: nil) else { throw ClipError.noStream("video") }
        let decoder = try Decoder(input: input, stream: stream, x264Build: input.x264Build(stream: stream))
        input.seek(to: time)
        var image: CGImage?
        try decode(input: input, stream: stream, decoder: decoder) { frame in
            let pts = frame.pointee.best_effort_timestamp
            // Decode forward from the keyframe until the requested moment.
            if pts != Int64.min, decoder.seconds(pts) + 0.02 < time { return true }
            image = try makeImage(frame, maxWidth: maxWidth)
            return false
        }
        guard let image else { throw ClipError.empty }
        try? FileManager.default.removeItem(at: output)
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ClipError.failed("jpeg")
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ClipError.failed("jpeg") }
    }

    // MARK: Animated picture

    /// Width and frame rate of an animated picture, tried in order until it fits `animationMaxBytes`.
    static let animationSteps: [(width: Int, fps: Double)] = [(480, 12), (360, 10), (320, 8)]
    /// Kept small for the AnkiConnect upload and for AnkiWeb sync.
    public static let animationMaxBytes = 3_000_000
    /// Longer lines are cut to this.
    static let animationMaxSeconds = 8.0

    /// Writes `start`–`end` as a looping animated GIF (ImageIO picks each frame's palette).
    private static func grabAnimation(input: Input, start: Double, end: Double, output: URL) throws {
        guard let stream = input.stream(AVMEDIA_TYPE_VIDEO, preferred: nil) else { throw ClipError.noStream("video") }
        let decoder = try Decoder(input: input, stream: stream, x264Build: input.x264Build(stream: stream))
        let end = min(max(end, start + 0.5), start + animationMaxSeconds)
        let first = animationSteps[0]
        var frames: [(time: Double, image: CGImage)] = []
        var nextTime = start
        var sawKeyframe = false
        input.seek(to: start)
        try decode(input: input, stream: stream, decoder: decoder) { frame in
            let pts = frame.pointee.best_effort_timestamp
            // Frames decoded before the first keyframe (open-GOP leading pictures) refer to
            // frames before the seek and come out as coloured blocks.
            if frame.pointee.flags & 2 != 0 { sawKeyframe = true } // AV_FRAME_FLAG_KEY
            guard sawKeyframe, pts != Int64.min else { return true }
            let time = decoder.seconds(pts)
            if time > end { return false }
            if time + 0.02 < nextTime { return true }
            frames.append((time, try makeImage(frame, maxWidth: first.width)))
            while nextTime <= time + 0.02 { nextTime += 1 / first.fps }
            return true
        }
        guard frames.count > 1 else { throw ClipError.empty }
        var data = Data()
        for (index, step) in animationSteps.enumerated() {
            let picked = index == 0 ? frames : thinned(frames, fps: step.fps)
            data = try gif(picked.map { (time: $0.time, image: index == 0 ? $0.image : try scaled($0.image, width: step.width)) },
                           end: end)
            if data.count <= animationMaxBytes { break }
        }
        try data.write(to: output, options: .atomic)
    }

    /// Every frame at least `1 / fps` after the one kept before it.
    private static func thinned(_ frames: [(time: Double, image: CGImage)], fps: Double) -> [(time: Double, image: CGImage)] {
        var kept: [(time: Double, image: CGImage)] = []
        for frame in frames where kept.last.map({ frame.time - $0.time >= 1 / fps - 0.005 }) ?? true {
            kept.append(frame)
        }
        return kept
    }

    private static func scaled(_ image: CGImage, width: Int) throws -> CGImage {
        guard image.width > width else { return image }
        let height = max(2, Int(Double(image.height) * Double(width) / Double(image.width)) & ~1)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else {
            throw ClipError.failed("scaler")
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let result = context.makeImage() else { throw ClipError.failed("scaler") }
        return result
    }

    /// The frames as a looping GIF, each shown until the next one's time (the last until `end`).
    private static func gif(_ frames: [(time: Double, image: CGImage)], end: Double) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, frames.count, nil) else {
            throw ClipError.failed("gif")
        }
        let loop = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]]
        CGImageDestinationSetProperties(destination, loop as CFDictionary)
        for (index, frame) in frames.enumerated() {
            let next = index + 1 < frames.count ? frames[index + 1].time : max(end, frame.time + 0.05)
            let delay = max(0.02, next - frame.time)
            let properties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay,
                                                              kCGImagePropertyGIFUnclampedDelayTime: delay]]
            CGImageDestinationAddImage(destination, frame.image, properties as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { throw ClipError.failed("gif") }
        return data as Data
    }

    /// Converts a decoded frame (any pixel format) to an sRGB image no wider than `maxWidth`.
    private static func makeImage(_ frame: UnsafeMutablePointer<AVFrame>, maxWidth: Int) throws -> CGImage {
        let sourceWidth = Int(frame.pointee.width), sourceHeight = Int(frame.pointee.height)
        guard sourceWidth > 0, sourceHeight > 0 else { throw ClipError.empty }
        // Account for anamorphic video (non-square pixels).
        let aspect = frame.pointee.sample_aspect_ratio
        let pixelAspect = aspect.num > 0 && aspect.den > 0 ? Double(aspect.num) / Double(aspect.den) : 1
        let displayWidth = Double(sourceWidth) * pixelAspect
        let scale = min(1, Double(maxWidth) / displayWidth)
        let width = max(2, Int(displayWidth * scale) & ~1), height = max(2, Int(Double(sourceHeight) * scale) & ~1)

        guard let scaler = sws_getContext(Int32(sourceWidth), Int32(sourceHeight), AVPixelFormat(frame.pointee.format),
                                          Int32(width), Int32(height), AV_PIX_FMT_BGRA, Int32(bitPattern: SWS_BICUBIC.rawValue),
                                          nil as UnsafeMutablePointer<SwsFilter>?, nil as UnsafeMutablePointer<SwsFilter>?,
                                          nil as UnsafePointer<Double>?) else {
            throw ClipError.failed("scaler")
        }
        defer { sws_freeContext(scaler) }
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        var data = frame.pointee.data
        var lines = frame.pointee.linesize
        pixels.withUnsafeMutableBufferPointer { buffer in
            var destination: [UnsafeMutablePointer<UInt8>?] = [buffer.baseAddress, nil, nil, nil]
            var strides: [Int32] = [Int32(bytesPerRow), 0, 0, 0]
            withUnsafePointer(to: &data) { dataTuple in
                withUnsafePointer(to: &lines) { lineTuple in
                    dataTuple.withMemoryRebound(to: UnsafePointer<UInt8>?.self, capacity: 8) { planes in
                        lineTuple.withMemoryRebound(to: Int32.self, capacity: 8) { linesizes in
                            _ = sws_scale(scaler, planes, linesizes, 0, Int32(sourceHeight), &destination, &strides)
                        }
                    }
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
            throw ClipError.failed("image")
        }
        return image
    }
}
