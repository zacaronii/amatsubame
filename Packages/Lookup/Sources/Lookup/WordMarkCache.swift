import Core
import Dictionary
import Foundation
import Observation

/// Word marks for short lines of text (subtitles, transcript lines): each line is split into
/// words once, in the background, and the words' Anki states are applied when shown, so an
/// Anki refresh restyles lines without splitting them again.
@MainActor @Observable
public final class WordMarkCache {
    /// Words found in each line, by the line's text.
    private var spans: [String: [WordSpan]] = [:]
    @ObservationIgnored private var pending: Set<String> = []
    @ObservationIgnored private var snapshot: (revision: Int, marks: WordMarks)?
    @ObservationIgnored private let service: LookupService
    static let limit = 20_000

    public init(service: LookupService) {
        self.service = service
    }

    /// Splits these lines in the background (call when a track or transcript loads), in the
    /// order given, showing marks every few lines: put the lines on screen first.
    public func prepare(_ lines: [String]) {
        var seen = Set<String>()
        let todo = lines.filter { spans[$0] == nil && !pending.contains($0) && !$0.isEmpty && seen.insert($0).inserted }
        guard !todo.isEmpty, service.mining?.marksWords ?? false else { return }
        pending.formUnion(todo)
        let scanner = service.library.scanner
        Task {
            // Before the dictionaries load every line would come back empty: wait for them
            // (up to a minute; with none installed, the lines are tried again when shown).
            var waited = 0
            while !(await scanner.isReady), waited < 120 {
                try? await Task.sleep(for: .milliseconds(500))
                waited += 1
            }
            guard await scanner.isReady else {
                pending.subtract(todo)
                return
            }
            for batch in stride(from: 0, to: todo.count, by: 20).map({ todo[$0..<min($0 + 20, todo.count)] }) {
                var found: [String: [WordSpan]] = [:]
                for line in batch { found[line] = await scanner.words(in: line) }
                if spans.count > Self.limit { spans.removeAll() }
                spans.merge(found) { $1 }
                pending.subtract(batch)
            }
        }
    }

    /// The marked characters of `line` (character indexes, as `TappableLine` counts them) and
    /// how each is marked. Known words and unsplit lines have none.
    public func marks(for line: String) -> [Int: WordMarkState] {
        guard let mining = service.mining, mining.marksWords else { return [:] }
        guard let words = spans[line] else {
            prepare([line])
            return [:]
        }
        let marks = currentMarks(mining)
        var result: [Int: WordMarkState] = [:]
        let utf16 = Array(line.utf16)
        for word in words {
            let state = marks.state(expression: word.expression, reading: word.reading)
            guard state != .known, word.offset + word.length <= utf16.count else { continue }
            let start = String(decoding: utf16[..<word.offset], as: UTF16.self).count
            let count = String(decoding: utf16[word.offset..<word.offset + word.length], as: UTF16.self).count
            for index in start..<start + count { result[index] = state }
        }
        return result
    }

    /// The mined words' states, re-read when they change (Anki refresh, a card mined).
    private func currentMarks(_ mining: MiningService) -> WordMarks {
        if let snapshot, snapshot.revision == mining.revision { return snapshot.marks }
        let marks = mining.wordMarks()
        snapshot = (mining.revision, marks)
        return marks
    }
}
