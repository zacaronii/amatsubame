import Foundation
import KikuWatchLink
import Observation

/// Listening on this watch, kept until the phone has it (docs/KIKU_PLAN.md milestone 3). Each
/// stretch grows while you listen; it's sent on pause and at the end (and with Sync Now), and
/// dropped only once the phone acknowledges that version, so nothing is lost when the phone is
/// out of reach or the watch app is closed.
@MainActor @Observable
final class WatchListeningLog {
    private(set) var pending: [WatchListening]
    /// When the phone last acknowledged something.
    private(set) var lastSynced: Date?

    /// Sends the pending stretches to the phone (set by `WatchSession`).
    @ObservationIgnored var send: (([WatchListening]) -> Void)?

    private static let pendingKey = "kiku.watch.listening"
    private static let syncedKey = "kiku.watch.lastSynced"

    init() {
        pending = UserDefaults.standard.data(forKey: Self.pendingKey)
            .flatMap { try? JSONDecoder().decode([WatchListening].self, from: $0) } ?? []
        lastSynced = UserDefaults.standard.object(forKey: Self.syncedKey) as? Date
    }

    /// `seconds` of playback of `item`, now at `position`.
    func listened(_ seconds: Double, item: WatchItem, position: Double, rate: Double, at date: Date = .now, finished: Bool = false) {
        guard seconds > 0 || finished else { return }
        if let last = pending.indices.last, pending[last].continues(item.key, at: date) {
            pending[last].add(seconds, at: position, rate: rate, on: date, finished: finished)
        } else {
            var stretch = WatchListening(item: item, position: max(position - seconds * rate, 0), rate: rate,
                                         at: date.addingTimeInterval(-seconds))
            stretch.add(seconds, at: position, rate: rate, on: date, finished: finished)
            pending.append(stretch)
        }
        save()
    }

    /// Sends what the phone doesn't have yet.
    func flush() {
        guard !pending.isEmpty else { return }
        send?(pending)
    }

    /// The phone has these versions: drop them (a stretch that grew since stays).
    func acknowledge(_ applied: [String: Date]) {
        let before = pending.count
        pending.removeAll { stretch in applied[stretch.id].map { $0 >= stretch.endedAt } ?? false }
        guard pending.count != before else { return }
        lastSynced = .now
        UserDefaults.standard.set(lastSynced, forKey: Self.syncedKey)
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(pending) { UserDefaults.standard.set(data, forKey: Self.pendingKey) }
    }
}
