import AppCommon
import Core
import CoreGraphics
import Foundation
import ImageIO
import KikuIntents
import UniformTypeIdentifiers
#if canImport(WidgetKit)
import WidgetKit
#endif

/// Keeps the widgets' snapshot up to date: what's playing (or last played), whether it's
/// playing, and the next two. Written to the App Group when it changes, with the covers it
/// shows; the widgets and Control Center are then told to reload. Does nothing without the
/// App Group.
@MainActor
final class KikuWidgetPublisher {
    private weak var environment: KikuEnvironment?
    private let store = WidgetSnapshotStore.inAppGroup()
    private var pending: Task<Void, Never>?

    init(environment: KikuEnvironment) {
        self.environment = environment
    }

    /// Soon (changes come in bursts: a new episode, its progress, the queue).
    func update() {
        guard store != nil else { return }
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await self?.publish()
        }
    }

    private func publish() async {
        guard let store, let environment else { return }
        let snapshot = Self.snapshot(playing: environment.playback.map { ($0.entry, $0.audio.currentTime, $0.audio.isPlaying) },
                                     lastPlayed: environment.library.continueListening.first,
                                     upNext: environment.upNextFlat.map(\.item),
                                     continueListening: environment.library.continueListening)
        let shown = Set(([snapshot.current] + snapshot.next.map(Optional.some)).compactMap { $0?.itemId })
        for itemId in shown where !store.hasCover(itemId: itemId) {
            if let data = await cover(itemId) { try? store.saveCover(data, itemId: itemId) }
        }
        store.pruneCovers(keeping: shown)
        guard (try? store.write(snapshot)) == true else { return }
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }

    /// A small JPEG of a show's or book's cover, for the widgets.
    private func cover(_ itemId: String) async -> Data? {
        guard let client = environment?.audiobookshelfClient(),
              let request = try? await client.coverRequest(itemId: itemId, width: 300),
              let image = try? await CoverLoader.image(for: request, maxPixelSize: 300) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// What the widgets show. The current one is what's loaded, else the first in Continue
    /// Listening; the next two are Up Next's, else Continue Listening's after the current.
    static func snapshot(playing: (entry: EpisodeEntry, time: Double, isPlaying: Bool)?, lastPlayed: EpisodeEntry?,
                         upNext: [UpNextItem], continueListening: [EpisodeEntry], now: Date = .now) -> WidgetSnapshot {
        let current: WidgetSnapshot.Item? = if let playing {
            item(playing.entry, time: playing.time)
        } else {
            lastPlayed.map { item($0, time: $0.progress?.currentTime ?? 0) }
        }
        let next: [WidgetSnapshot.Item]
        let title: String
        if !upNext.isEmpty {
            title = "Up Next"
            next = upNext.prefix(2).map { WidgetSnapshot.Item(key: $0.key, itemId: $0.itemId, title: $0.title, show: $0.showTitle, timeLeft: 0, fraction: 0) }
        } else {
            title = "Continue Listening"
            next = continueListening.filter { $0.id != current?.key }.prefix(2)
                .map { item($0, time: $0.progress?.currentTime ?? 0) }
        }
        return WidgetSnapshot(current: current, isPlaying: playing?.isPlaying ?? false, nextTitle: next.isEmpty ? "" : title,
                              next: next, updatedAt: now)
    }

    private static func item(_ entry: EpisodeEntry, time: Double) -> WidgetSnapshot.Item {
        let duration = entry.duration
        return WidgetSnapshot.Item(key: entry.id, itemId: entry.itemId, title: entry.episode.title,
                                   show: entry.isBook ? (entry.book?.media.metadata.authorName ?? "") : entry.showTitle,
                                   timeLeft: max(duration - time, 0), fraction: duration > 0 ? min(time / duration, 1) : 0)
    }
}
