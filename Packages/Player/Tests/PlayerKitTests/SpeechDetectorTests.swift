import Foundation
import Testing
@testable import PlayerKit

@Suite struct SpeechDetectorTests {
    /// A voice-like sound: a 140 Hz buzz with harmonics, swelling like syllables.
    static func voice(seconds: Double) -> [Int16] {
        let rate = Double(SpeechDetector.sampleRate)
        return (0..<Int(seconds * rate)).map { n in
            let t = Double(n) / rate
            let syllables = 0.55 + 0.45 * sin(2 * .pi * 4 * t)
            var value = 0.0
            for harmonic in 1...12 {
                // Formant-ish emphasis around 500–1500 Hz.
                let frequency = 140.0 * Double(harmonic)
                let emphasis = exp(-pow((frequency - 900) / 600, 2))
                value += emphasis * sin(2 * .pi * frequency * t) / Double(harmonic).squareRoot()
            }
            return Int16(max(-1, min(1, value * syllables * 0.3)) * 32767)
        }
    }

    @Test func findsSpeechBetweenSilences() {
        let detector = SpeechDetector()
        let silence = [Int16](repeating: 0, count: SpeechDetector.sampleRate * 2)
        for part in [silence, Self.voice(seconds: 1.5), silence, Self.voice(seconds: 2), silence] {
            part.withUnsafeBufferPointer { detector.add($0) }
        }
        let spans = SubtitleSync.merged(detector.finish().map { SubtitleSync.Span(start: $0.start - 0.3, end: $0.end + 0.3) })
        #expect(spans.count == 2)
        #expect(abs((spans.first?.start ?? 0) + 0.3 - 2) < 0.4)
        #expect(abs((spans.last?.start ?? 0) + 0.3 - 5.5) < 0.4)
        #expect(abs(detector.time - 9.5) < 0.02)
    }

    @Test func silenceHasNoSpeech() {
        let detector = SpeechDetector()
        let silence = [Int16](repeating: 0, count: SpeechDetector.sampleRate * 5)
        silence.withUnsafeBufferPointer { detector.add($0) }
        #expect(detector.finish().isEmpty)
    }
}
