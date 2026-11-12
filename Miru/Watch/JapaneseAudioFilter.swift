import Core
import Foundation
import JellyfinKit

extension PlayerEnvironment {
    /// The movies and series in `items` with a Japanese audio track (Settings ▸ Libraries ▸
    /// Japanese Audio Only). Movies need their `mediaStreams`; series are told by their first
    /// episode, checked 6 at a time and saved, so only new series are checked again.
    /// `progress` gets (checked, to check) while series are checked. A series whose check
    /// fails is left out this time and checked again next time.
    func japaneseAudioOnly(_ items: [JellyfinItem], client: JellyfinClient,
                           progress: @escaping (Int, Int) -> Void = { _, _ in }) async -> [JellyfinItem] {
        let series = items.filter { $0.type == "Series" }.map(\.id)
        var answers = (try? audioChecks.answers(for: series)) ?? [:]
        let unchecked = series.filter { answers[$0] == nil }
        if !unchecked.isEmpty {
            var checks: [JellyfinAudioCheck] = []
            progress(0, unchecked.count)
            await withTaskGroup(of: JellyfinAudioCheck?.self) { group in
                var next = unchecked.makeIterator()
                func addNext() {
                    guard let id = next.next() else { return }
                    group.addTask {
                        do {
                            let episode = try await client.firstEpisode(seriesId: id)
                            return JellyfinAudioCheck(itemId: id, hasJapanese: episode?.hasJapaneseAudio ?? false)
                        } catch {
                            return nil
                        }
                    }
                }
                for _ in 0..<6 { addNext() }
                var done = 0
                for await check in group {
                    done += 1
                    progress(done, unchecked.count)
                    if let check { checks.append(check) }
                    addNext()
                }
            }
            try? audioChecks.save(checks)
            for check in checks { answers[check.itemId] = check.hasJapanese }
        }
        return items.filter { $0.type == "Series" ? answers[$0.id] == true : $0.hasJapaneseAudio }
    }
}
