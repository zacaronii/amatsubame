import Foundation

/// What plays after an episode, and when to offer it.
public enum JellyfinUpNext {
    /// The episodes after `itemId` in the series' order (seasons in order, as Jellyfin lists
    /// them); empty when it's the last one or isn't in the list.
    public static func episodes(after itemId: String, in episodes: [JellyfinItem]) -> [JellyfinItem] {
        guard let index = episodes.firstIndex(where: { $0.id == itemId }) else { return [] }
        return Array(episodes[(index + 1)...])
    }

    /// The episode before `itemId` in the series' order (the `<` key), if any.
    public static func episode(before itemId: String, in episodes: [JellyfinItem]) -> JellyfinItem? {
        guard let index = episodes.firstIndex(where: { $0.id == itemId }), index > 0 else { return nil }
        return episodes[index - 1]
    }

    /// Seconds before the end at which the card shows when Jellyfin has no credits marked.
    public static let fallbackLead: Double = 20

    /// When to offer the next episode: when the credits start, else `fallbackLead` before the
    /// end (nil while the length is unknown, or for very short videos).
    public static func offerTime(duration: Double, creditsStart: Double?) -> Double? {
        if let creditsStart, creditsStart > 0 { return creditsStart }
        guard duration > fallbackLead * 2 else { return nil }
        return duration - fallbackLead
    }

    /// Suggestions from Jellyfin's similar items: the same library first, never a hidden one,
    /// at most `limit`. `libraries` maps item ids to their library (missing: unknown).
    public static func suggestions(_ similar: [JellyfinItem], libraries: [String: String], currentLibrary: String?,
                                   hidden: Set<String>, limit: Int = 3) -> [JellyfinItem] {
        let visible = similar.filter { item in libraries[item.id].map { !hidden.contains($0) } ?? true }
        let same = visible.filter { currentLibrary != nil && libraries[$0.id] == currentLibrary }
        let others = visible.filter { !same.contains($0) }
        return Array((same + others).prefix(limit))
    }
}
