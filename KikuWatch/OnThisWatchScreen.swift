import KikuWatchLink
import SwiftUI

/// What's on this watch, or on its way: each item's state (waiting, %, ready, failed with
/// Retry), Remove, and the space left (docs/KIKU_PLAN.md milestone 2).
struct OnThisWatchScreen: View {
    @Environment(WatchSession.self) private var session

    var body: some View {
        let downloads = session.downloads
        List {
            if downloads.items.isEmpty {
                Text("Send episodes and books here from Kiku on your iPhone: Send to Watch, in the ⋯ menu or with a long press.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
            }
            ForEach(downloads.items) { item in
                OnThisWatchRow(item: item, status: downloads.statuses[item.key] ?? WatchItemStatus(state: .waiting))
                    .swipeActions {
                        Button("Remove", systemImage: "trash", role: .destructive) {
                            Task { await downloads.remove(item) }
                        }
                    }
            }
            if let free = downloads.freeBytes {
                Text("\(WatchItemStatus.size(free)) free")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
            }
        }
        .navigationTitle("On This Watch")
        .task { await downloads.reconcile() }
    }
}

private struct OnThisWatchRow: View {
    @Environment(WatchSession.self) private var session
    let item: WatchItem
    let status: WatchItemStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.title).font(.footnote.weight(.semibold)).lineLimit(2)
            Text(item.subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            Text(status.text)
                .font(.caption2)
                .foregroundStyle(status.state == .failed ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                .lineLimit(2)
            if status.state == .downloading {
                ProgressView(value: status.fraction ?? 0)
            }
            if status.state == .failed {
                Button("Retry", systemImage: "arrow.clockwise") {
                    Task { await session.downloads.retry(item) }
                }
                .font(.caption)
            }
        }
        .accessibilityIdentifier("watch.onThisWatch.row")
    }
}
