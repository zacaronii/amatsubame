import KikuWatchLink
import SwiftUI

/// Send to Watch, or Remove from Watch once it's on the list (docs/KIKU_PLAN.md milestone 2).
/// Only on an iPhone with a paired watch that has Kiku.
struct SendToWatchButton: View {
    @Environment(KikuEnvironment.self) private var environment
    let entry: EpisodeEntry

    var body: some View {
        #if os(iOS)
        let library = environment.watchLibrary
        if library.isWatchAppInstalled, entry.fileCount == 1, entry.episode.audioFile != nil {
            if library.contains(entry.id) {
                Button("Remove from Watch", systemImage: "applewatch.slash") { library.remove(entry.id) }
            } else {
                Button("Send to Watch", systemImage: "applewatch") { Task { await library.send(entry) } }
                    .accessibilityIdentifier("sendToWatch")
            }
        }
        #endif
    }
}

#if os(iOS)
/// Settings ▸ Storage's On Apple Watch: what's sent, each item's state on the watch, its free
/// space, and Remove.
struct OnWatchSection: View {
    @Environment(KikuEnvironment.self) private var environment

    var body: some View {
        let library = environment.watchLibrary
        if library.isWatchAppInstalled || !library.items.isEmpty {
            Section {
                if library.items.isEmpty {
                    Text("Nothing yet. Send an episode or a book to your watch from its ⋯ menu, a long press on it, or the player.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                if !library.items.isEmpty {
                    Button("Sync Now", systemImage: "arrow.triangle.2.circlepath") { environment.watch.syncNow() }
                }
                ForEach(library.items) { item in
                    OnWatchRow(item: item, status: library.status(item.key), staleness: library.staleness(item.key),
                               sending: library.sendingText(item.key))
                        .swipeActions {
                            Button("Remove", systemImage: "trash", role: .destructive) { library.remove(item.key) }
                        }
                        .swipeActions(edge: .leading) {
                            if library.canSendFromPhone(item.key) {
                                Button("Send from iPhone", systemImage: "iphone.and.arrow.forward") { library.sendFromPhone(item.key) }
                                    .tint(.accentColor)
                            }
                        }
                        .contextMenu {
                            if library.canSendFromPhone(item.key) {
                                Button("Send from iPhone", systemImage: "iphone.and.arrow.forward") { library.sendFromPhone(item.key) }
                            }
                            Button("Remove from Watch", systemImage: "trash", role: .destructive) { library.remove(item.key) }
                        }
                }
            } header: {
                Text("On Apple Watch")
            } footer: {
                Text(footer(library))
            }
        }
    }

    private func footer(_ library: WatchLibraryModel) -> String {
        var parts = ["The watch downloads these from Audiobookshelf itself. With your iPhone nearby, watchOS sends it through the iPhone over Bluetooth, which can be slow for a book; watchOS favours big downloads while the watch charges.",
                     "If the watch can't reach your server (on a VPN or only at home), long-press one that's downloaded on this iPhone and choose Send from iPhone."]
        if let inventory = library.inventory {
            if let free = inventory.freeBytes { parts.append("\(WatchItemStatus.size(free)) free on the watch.") }
            parts.append("Last heard from \(inventory.updatedAt.formatted(.relative(presentation: .named))).")
        }
        if library.rules.isOn { parts.append("Automatic rules: Settings ▸ Downloads ▸ Apple Watch.") }
        if let message = library.rulesMessage { parts.append(message) }
        if let synced = library.lastSynced {
            parts.append("Listening on the watch last synced \(synced.formatted(.relative(presentation: .named))).")
        }
        return parts.joined(separator: " ")
    }
}

private struct OnWatchRow: View {
    let item: WatchItem
    let status: WatchItemStatus
    var staleness: String?
    /// Send Now's progress, or why it failed.
    var sending: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(item.title).lineLimit(1)
            Text("\(item.subtitle) · \(Self.reason(item.reason))").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Text(status.text)
                .font(.caption)
                .foregroundStyle(status.state == .failed ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            if status.state == .downloading {
                ProgressView(value: status.fraction ?? 0)
            }
            if let sending {
                Text(sending).font(.caption).foregroundStyle(.secondary)
            }
            if let staleness {
                Text(staleness).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .accessibilityIdentifier("onWatch.row")
    }

    /// Why it's there, as Storage names the phone's downloads.
    static func reason(_ reason: WatchItem.Reason?) -> String {
        switch reason {
        case nil: "By hand"
        case .started: "Started"
        case .ahead: "Ahead"
        }
    }
}
#endif
