import CFVad
import Foundation

/// Finds speech in 8 kHz mono audio with WebRTC's voice activity detector (libfvad, the one
/// alass uses), as time spans for `SubtitleSync`.
public final class SpeechDetector {
    public static let sampleRate = 8000
    /// 10 ms frames.
    static let frameLength = 80

    private let vad: OpaquePointer
    private var pending: [Int16] = []
    private var frames = 0
    private var speechStart: Double?
    private(set) public var spans: [SubtitleSync.Span] = []
    /// Shorter bursts are dropped (clicks, single syllables of music).
    let minimumSpeech: Double

    /// `mode` 0–3: higher rejects more non-speech (music, effects) and misses more speech.
    /// Mode 1 matched subtitles best on the episodes tested (2 and 3 drop too much speech
    /// under music, or let songs through as speech in odd places).
    public static let defaultMode: Int32 = 1

    public init(mode: Int32 = SpeechDetector.defaultMode, minimumSpeech: Double = 0.3) {
        vad = fvad_new()
        fvad_set_mode(vad, mode)
        fvad_set_sample_rate(vad, Int32(Self.sampleRate))
        self.minimumSpeech = minimumSpeech
    }

    deinit { fvad_free(vad) }

    /// The time reached so far, in seconds.
    public var time: Double { Double(frames) * Double(Self.frameLength) / Double(Self.sampleRate) }

    public func add(_ samples: UnsafeBufferPointer<Int16>) {
        pending.append(contentsOf: samples)
        var offset = 0
        pending.withUnsafeBufferPointer { buffer in
            while offset + Self.frameLength <= buffer.count {
                let voiced = fvad_process(vad, buffer.baseAddress! + offset, Self.frameLength) == 1
                mark(voiced)
                offset += Self.frameLength
            }
        }
        pending.removeFirst(offset)
    }

    /// Ends the last span; returns all of them.
    public func finish() -> [SubtitleSync.Span] {
        mark(false)
        return spans
    }

    private func mark(_ voiced: Bool) {
        let now = time
        frames += 1
        if voiced, speechStart == nil {
            speechStart = now
        } else if !voiced, let start = speechStart {
            speechStart = nil
            if now - start >= minimumSpeech { spans.append(SubtitleSync.Span(start: start, end: now)) }
        }
    }
}
