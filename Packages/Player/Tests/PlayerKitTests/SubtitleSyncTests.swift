import Foundation
import Testing
@testable import PlayerKit

@Suite struct SubtitleSyncTests {
    typealias Span = SubtitleSync.Span

    /// Repeatable random numbers.
    struct Seeded: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }

    /// About 22 minutes of dialogue: lines of 0.8–4 s with gaps of 0.3–4 s.
    static func episode(seed: UInt64 = 1) -> [Span] {
        var random = Seeded(state: seed)
        var spans: [Span] = []
        var time = 5.0
        while time < 1320 {
            let length = Double.random(in: 0.8...4, using: &random)
            spans.append(Span(start: time, end: time + length))
            time += length + Double.random(in: 0.3...4, using: &random)
        }
        return spans
    }

    /// The same speech as another source would time it: edges off by up to 0.15 s, some
    /// lines missing and some extra (signs, songs, a different translation's splits).
    static func reference(for spans: [Span], seed: UInt64 = 2) -> [Span] {
        var random = Seeded(state: seed)
        var result: [Span] = []
        for span in spans {
            if Double.random(in: 0...1, using: &random) < 0.1 { continue }
            result.append(Span(start: span.start + Double.random(in: -0.15...0.15, using: &random),
                               end: span.end + Double.random(in: -0.15...0.15, using: &random)))
            if Double.random(in: 0...1, using: &random) < 0.1 {
                let start = span.end + 0.2
                result.append(Span(start: start, end: start + Double.random(in: 0.3...1, using: &random)))
            }
        }
        return result
    }

    static func shifted(_ spans: [Span], _ shift: (Double) -> Double) -> [Span] {
        spans.map { Span(start: $0.start + shift($0.start), end: $0.end + shift($0.start)) }
    }

    @Test func findsAConstantShift() throws {
        let truth = Self.episode()
        // The subtitle is 3.42 s early: it needs moving 3.42 s later.
        let subtitle = Self.shifted(truth) { _ in -3.42 }
        let result = try #require(SubtitleSync.align(subtitle, to: Self.reference(for: truth)))
        #expect(result.parts.count == 1)
        #expect(abs(result.shift(at: 100) - 3.42) <= 0.05)
        #expect(result.match > 0.7)
    }

    @Test func leavesAGoodFileAlone() throws {
        let truth = Self.episode(seed: 7)
        let result = try #require(SubtitleSync.align(truth, to: Self.reference(for: truth, seed: 8)))
        #expect(result.parts.count == 1)
        #expect(abs(result.shift(at: 0)) <= 0.05)
    }

    @Test func findsASplit() throws {
        let truth = Self.episode(seed: 3)
        // An ad break in the subtitle's source: before 600 s it's 1 s late, after it 4.5 s early.
        let subtitle = Self.shifted(truth) { $0 < 600 ? 1 : -4.5 }
        let result = try #require(SubtitleSync.align(subtitle, to: Self.reference(for: truth, seed: 4)))
        #expect(result.parts.count == 2)
        #expect(abs(result.shift(at: 100) + 1) <= 0.05)
        #expect(abs(result.shift(at: 1000) - 4.5) <= 0.05)
        let boundary = try #require(result.parts.last?.from)
        #expect(abs(boundary - 600) < 10)
    }

    @Test func withoutSplitsItFindsTheBestSingleShift() throws {
        let truth = Self.episode(seed: 5)
        let subtitle = Self.shifted(truth) { $0 < 300 ? 1 : -4.5 }
        let result = try #require(SubtitleSync.align(subtitle, to: Self.reference(for: truth, seed: 6),
                                                     options: .init(allowsSplits: false)))
        #expect(result.parts.count == 1)
        // Most of the episode is after 300 s.
        #expect(abs(result.shift(at: 0) - 4.5) <= 0.05)
    }

    @Test func linesKeepTheirOrder() throws {
        let truth = Self.episode(seed: 9)
        let subtitle = Self.shifted(truth) { $0 < 500 ? 2 : ($0 < 900 ? -6 : 0.5) }
        let result = try #require(SubtitleSync.align(subtitle, to: Self.reference(for: truth, seed: 10)))
        let synced = Self.shifted(SubtitleSync.merged(subtitle)) { result.shift(at: $0) }
        for (a, b) in zip(synced, synced.dropFirst()) {
            #expect(b.start >= a.end - 0.001)
        }
        #expect(abs(result.shift(at: 1000) + 0.5) <= 0.05)
    }

    @Test func tooLittleToGoOn() {
        #expect(SubtitleSync.align([Span(start: 1, end: 2)], to: Self.episode()) == nil)
    }

    @Test func retimingKeepsStylingAndMovesEachPart() {
        let ass = """
        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,0:00:10.00,0:00:12.50,Default,,0,0,0,,{\\i1}最初{\\i0}
        Dialogue: 0,0:10:00.00,0:10:02.00,Default,,0,0,0,,後半
        """
        let result = SubtitleSync.Result(parts: [.init(from: -.infinity, shift: 1.5), .init(from: 300, shift: -2)], match: 1)
        let text = SubtitleFile.retimed(ass, format: .ass) { result.shift(at: $0) }
        #expect(text.contains("Dialogue: 0,0:00:11.50,0:00:14.00,Default,,0,0,0,,{\\i1}最初{\\i0}"))
        #expect(text.contains("Dialogue: 0,0:09:58.00,0:10:00.00,Default,,0,0,0,,後半"))
        let srt = "1\n00:00:10,000 --> 00:00:12,500\n最初\n\n2\n00:10:00,000 --> 00:10:02,000\n後半\n"
        let retimed = SubtitleFile.retimed(srt, format: .srt) { result.shift(at: $0) }
        #expect(retimed.contains("00:00:11,500 --> 00:00:14,000") && retimed.contains("00:09:58,000 --> 00:10:00,000"))
    }
}
