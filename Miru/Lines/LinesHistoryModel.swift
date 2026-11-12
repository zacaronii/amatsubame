import Core
import Foundation
import JellyfinKit
import Observation

/// Episodes and movies watched or started on any device, from the visible libraries,
/// newest first. Offline it shows the transcripts saved on this device.
@MainActor @Observable
final class LinesHistoryModel {
    struct Entry: Identifiable, Hashable {
        var id: String
        var show: String
        /// "S1E5 · Title", or the title for movies.
        var detail: String
        var imageTag: String?
        var lastPlayed: Date?
        /// Nil when unknown (offline rows).
        var hasJapanese: Bool?
        var isSaved: Bool
        var progress: Double?
    }

    private(set) var entries: [Entry] = []

    /// The history in runs: consecutive episodes of one show together, in history order.
    static func runs(_ entries: [Entry]) -> [[Entry]] {
        var runs: [[Entry]] = []
        for entry in entries {
            if let last = runs.last?.last, !entry.show.isEmpty, last.show == entry.show {
                runs[runs.count - 1].append(entry)
            } else {
                runs.append([entry])
            }
        }
        return runs
    }
    private(set) var error: String?
    private(set) var isLoading = false
    private(set) var canLoadMore = false

    @ObservationIgnored private let environment: PlayerEnvironment
    /// Next page start per library, and each library's total.
    @ObservationIgnored private var cursors: [String: (next: Int, total: Int)] = [:]
    @ObservationIgnored private var items: [String: JellyfinItem] = [:]
    static let pageSize = 30

    init(environment: PlayerEnvironment) {
        self.environment = environment
    }

    func refresh() async {
        let saved = (try? environment.transcripts.savedItemIds()) ?? []
        guard let client = environment.jellyfinClient() else {
            showSaved(saved)
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let libraries = try await client.views().filter { !environment.hiddenLibraries.contains($0.id) }
            cursors = [:]
            items = [:]
            for library in libraries {
                for item in try await client.resume(libraryId: library.id) { items[item.id] = item }
                try await loadPage(library: library.id, client: client)
            }
            publish(saved: saved)
            error = nil
        } catch {
            guard !error.isCancellation else { return }
            self.error = error.localizedDescription
            if entries.isEmpty { showSaved(saved) }
        }
    }

    /// Loads the next page of every library that has more.
    func loadMore() async {
        guard !isLoading, let client = environment.jellyfinClient() else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            for (library, cursor) in cursors where cursor.next < cursor.total {
                try await loadPage(library: library, client: client)
            }
            publish(saved: (try? environment.transcripts.savedItemIds()) ?? [])
        } catch {
            guard !error.isCancellation else { return }
            self.error = error.localizedDescription
        }
    }

    private func loadPage(library: String, client: JellyfinClient) async throws {
        let start = cursors[library]?.next ?? 0
        let page = try await client.playedItems(libraryId: library, startIndex: start, limit: Self.pageSize)
        for item in page.items { items[item.id] = item }
        cursors[library] = (start + page.items.count, page.totalRecordCount ?? start + page.items.count)
    }

    private func publish(saved: Set<String>) {
        entries = items.values
            .sorted { ($0.userData?.lastPlayedDate ?? .distantPast) > ($1.userData?.lastPlayedDate ?? .distantPast) }
            .map { item in
                Entry(
                    id: item.id, show: item.seriesName ?? item.name,
                    detail: item.seriesName == nil ? (item.productionYear.map(String.init) ?? "")
                        : [item.episodeLabel, item.name].compactMap(\.self).joined(separator: " · "),
                    imageTag: item.imageTags?["Primary"], lastPlayed: item.userData?.lastPlayedDate,
                    hasJapanese: item.mediaStreams.map { _ in item.japaneseSubtitle != nil }, isSaved: saved.contains(item.id),
                    progress: item.resumePosition.flatMap { position in item.duration.map { position / $0 } })
            }
        canLoadMore = cursors.values.contains { $0.next < $0.total }
    }

    private func showSaved(_ saved: Set<String>) {
        entries = ((try? environment.transcripts.recent()) ?? []).map { info in
            Entry(id: info.itemId, show: info.showName,
                  detail: info.seriesName == nil ? "" : [info.episodeLabel, info.title].compactMap(\.self).joined(separator: " · "),
                  imageTag: nil, lastPlayed: info.lastPlayedAt, hasJapanese: true, isSaved: true, progress: nil)
        }
        canLoadMore = false
    }
}
