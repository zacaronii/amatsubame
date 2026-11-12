import Core
import JellyfinKit

extension MediaSegmentStore {
    /// The item's intro, credits etc.: fetched and saved when online, the saved ones offline.
    func refresh(itemId: String, client: JellyfinClient?) async -> [JellyfinMediaSegment] {
        if let client, let fresh = try? await client.mediaSegments(itemId: itemId) {
            try? save(fresh.map { CachedMediaSegment(itemId: itemId, kind: $0.kind.rawValue, start: $0.start, end: $0.end) },
                      itemId: itemId)
            return fresh
        }
        return ((try? segments(itemId: itemId)) ?? []).compactMap { saved in
            JellyfinMediaSegment.Kind(rawValue: saved.kind).map { JellyfinMediaSegment(kind: $0, start: saved.start, end: saved.end) }
        }
    }
}

extension JellyfinMediaSegment {
    /// What the skip button says.
    var skipTitle: String {
        switch kind {
        case .intro: "Skip Intro"
        case .outro: "Skip Credits"
        case .recap: "Skip Recap"
        case .preview: "Skip Preview"
        case .commercial: "Skip Ad"
        }
    }

    /// Skipped on its own when "Skip Intros Automatically" is on.
    var skipsAutomatically: Bool { kind == .intro || kind == .recap }
}
