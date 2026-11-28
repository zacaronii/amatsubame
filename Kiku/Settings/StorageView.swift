import AppCommon
import Core
import SwiftUI

/// Settings ▸ Storage ▸ Downloaded: what's downloading and what's on the device, by show.
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
                if !reasonTotals.isEmpty {
                    Text(reasonTotals.map { "\($0.label) \($0.bytes.storageText)" }.joined(separator: " · "))
                        .font(.footnote).foregroundStyle(.secondary)
                        .accessibilityIdentifier("downloads.reasons")
                }
            }
            if let error = downloader.lastError {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            if all.isEmpty {
                DownloadsEmptySection("Download episodes from a show's page to listen offline. Nothing downloads unless you ask or turn on automatic downloads (Settings ▸ Download Rules).")
            }
            if !active.isEmpty {
                Section("Downloading") {
                    ForEach(active) { record in
                        DownloadRow(record: Self.withReason(record).withSeriesInDetail, waitingReason: waitingReason,
                                    onPause: { Task { await downloader.pause(record) } },
                                    onResume: { Task { await downloader.resume(record) } },
                                    onDelete: { Task { await downloader.delete(record) } })
                    }
                }
            }
            ForEach(groups) { group in
                Section {
                    ForEach(group.downloads) { record in
                        DownloadRow(record: withPlayedMark(Self.withReason(record)), onPause: {}, onResume: {},
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
            #if os(iOS)
            // On Apple Watch moved to Settings ▸ Apple Watch: say where.
            Section {} footer: {
                Text("What's on your Apple Watch is under Settings ▸ Apple Watch.")
                    .accessibilityIdentifier("storage.watchPointer")
            }
            #endif
        }
        .navigationTitle("Downloaded")
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

    /// Space used by each reason a download is on the device, largest first (only when there's
    /// more than downloads made by hand).
    private var reasonTotals: [(label: String, bytes: Int64)] {
        var bytes: [String: Int64] = [:]
        for record in all {
            bytes[Self.reasonLabel(record), default: 0] += record.state == .done ? (record.bytesTotal ?? 0) : record.bytesDone
        }
        guard bytes.keys.contains(where: { $0 != Self.reasonLabel(nil) }) else { return [] }
        return bytes.map { ($0.key, $0.value) }.sorted { $0.bytes > $1.bytes }
    }

    static func reasonLabel(_ reason: DownloadReason?) -> String {
        switch reason {
        case .ahead?: "Ahead"
        case .started?: "Started"
        case nil: "By Hand"
        }
    }

    static func reasonLabel(_ record: DownloadRecord) -> String {
        reasonLabel(EpisodeDownloader.metadata(record)?.reason)
    }

    /// Why it's on the device, in the row's detail ("By Hand", "Ahead", "Started").
    static func withReason(_ record: DownloadRecord) -> DownloadRecord {
        var record = record
        record.detail = [reasonLabel(record), record.detail].compactMap(\.self).filter { !$0.isEmpty }.joined(separator: " · ")
        return record
    }

    /// Finished episodes are marked so they're easy to clear.
    private func withPlayedMark(_ record: DownloadRecord) -> DownloadRecord {
        guard environment.library.progress[record.itemKey]?.isFinished == true else { return record }
        var record = record
        record.detail = [record.detail, "Played"].compactMap(\.self).joined(separator: " · ")
        return record
    }
}
