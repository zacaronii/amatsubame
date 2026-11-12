import AppCommon
import Core
import SwiftUI

/// Settings ▸ Storage ▸ Downloads: what's downloading and what's on the device, by show.
struct DownloadedEpisodesView: View {
    @Environment(KikuEnvironment.self) private var environment
    @Environment(CommonEnvironment.self) private var common
    @State private var confirmsDelete: DownloadGroup?

    private var downloader: EpisodeDownloader { environment.downloader }
    private var all: [DownloadRecord] { downloader.records.values.sorted { $0.createdAt < $1.createdAt } }
    private var active: [DownloadRecord] { all.filter { $0.state != .done } }
    private var groups: [DownloadGroup] { DownloadStore.grouped(all.filter { $0.state == .done }) }
    private var usedBytes: Int64 { all.reduce(0) { $0 + ($1.state == .done ? ($1.bytesTotal ?? 0) : $1.bytesDone) } }

    var body: some View {
        List {
            Section {
                DownloadStorageHeader(used: usedBytes)
            }
            if let error = downloader.lastError {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            if all.isEmpty {
                DownloadsEmptySection("Download episodes from a show's page to listen offline. Nothing downloads unless you ask.")
            }
            if !active.isEmpty {
                Section("Downloading") {
                    ForEach(active) { record in
                        DownloadRow(record: record.withSeriesInDetail, waitingReason: waitingReason,
                                    onPause: { Task { await downloader.pause(record) } },
                                    onResume: { Task { await downloader.resume(record) } },
                                    onDelete: { Task { await downloader.delete(record) } })
                    }
                }
            }
            ForEach(groups) { group in
                Section {
                    ForEach(group.downloads) { record in
                        DownloadRow(record: withPlayedMark(record), onPause: {}, onResume: {},
                                    onDelete: { Task { await downloader.delete(record) } })
                    }
                } header: {
                    HStack {
                        Text(group.seriesTitle)
                        Spacer()
                        Text(group.bytes.storageText)
                        Menu {
                            Button("Delete All", systemImage: "trash", role: .destructive) { confirmsDelete = group }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .menuIndicator(.hidden)
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
        .navigationTitle("Downloads")
        .confirmationDialog("Delete every downloaded episode of \(confirmsDelete?.seriesTitle ?? "")?",
                            isPresented: Binding(get: { confirmsDelete != nil }, set: { if !$0 { confirmsDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Delete \(confirmsDelete?.downloads.count ?? 0) Downloads", role: .destructive) {
                let records = confirmsDelete?.downloads ?? []
                Task { for record in records { await downloader.delete(record) } }
            }
        }
    }

    /// Why queued downloads aren't moving.
    private var waitingReason: String? {
        if !common.reachability.isOnline { return "Waiting for a connection" }
        if common.reachability.isExpensive && !DownloadSettings.load(common.database).allowsCellular { return "Waiting for Wi-Fi" }
        return nil
    }

    /// Finished episodes are marked so they're easy to clear.
    private func withPlayedMark(_ record: DownloadRecord) -> DownloadRecord {
        guard environment.library.progress[record.itemKey]?.isFinished == true else { return record }
        var record = record
        record.detail = [record.detail, "Played"].compactMap(\.self).joined(separator: " · ")
        return record
    }
}
