import KikuWatchLink
import SwiftUI

/// Play On (the iPhone or this watch) and what's on this watch, or on its way: each item's
/// state (waiting, %, ready, failed with Retry), Remove, and the space left (docs/KIKU_PLAN.md
/// milestone 2). Tapping one that's ready plays it here.
struct OnThisWatchScreen: View {
    @Environment(WatchSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let downloads = session.downloads
        List {
            Section("Play On") {
                modeRow(.phone, title: "iPhone", symbol: "iphone")
                modeRow(.watch, title: "This Watch", symbol: "applewatch")
            }
            if let problem = session.player.problem {
                Text(problem).font(.footnote).foregroundStyle(.orange).listRowBackground(Color.clear)
            }
            if downloads.items.isEmpty {
                Text("Send episodes and books here from Kiku on your iPhone: Send to Watch, in the ⋯ menu or with a long press.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
            }
            ForEach(downloads.items) { item in
                let status = downloads.statuses[item.key] ?? WatchItemStatus(state: .waiting)
                Button {
                    guard status.state == .ready else { return }
                    Task {
                        await session.playOnWatch(item)
                        if session.player.problem == nil { dismiss() }
                    }
                } label: {
                    OnThisWatchRow(item: item, status: status, isLoaded: session.player.item?.key == item.key)
                }
                    .swipeActions {
                        Button("Remove", systemImage: "trash", role: .destructive) {
                            Task { await downloads.remove(item) }
                        }
                    }
            }
            Section {
                Button("Sync Now", systemImage: "arrow.triangle.2.circlepath") { Task { await session.syncNow() } }
                    .accessibilityIdentifier("watch.syncNow")
            } footer: {
                Text(syncText)
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

    /// "Synced 2 min ago", or what's still waiting for the phone.
    private var syncText: String {
        let log = session.player.log
        if !log.pending.isEmpty {
            let count = log.pending.count
            return "\(count) listening \(count == 1 ? "session" : "sessions") waiting for your iPhone"
        }
        guard let synced = log.lastSynced else { return "Listening here goes to your iPhone when it's near." }
        return "Synced \(synced.formatted(.relative(presentation: .named)))"
    }

    private func modeRow(_ mode: WatchSession.Mode, title: String, symbol: String) -> some View {
        Button {
            session.setMode(mode)
            dismiss()
        } label: {
            HStack {
                Label(title, systemImage: symbol)
                Spacer()
                if session.mode == mode { Image(systemName: "checkmark").foregroundStyle(.tint) }
            }
        }
        .accessibilityIdentifier("watch.mode.\(mode.rawValue)")
    }
}

private struct OnThisWatchRow: View {
    @Environment(WatchSession.self) private var session
    let item: WatchItem
    let status: WatchItemStatus
    /// In this watch's player now.
    var isLoaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                if isLoaded { Image(systemName: "speaker.wave.2.fill").font(.caption2).foregroundStyle(.tint) }
                Text(item.title).font(.footnote.weight(.semibold)).lineLimit(2)
            }
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
