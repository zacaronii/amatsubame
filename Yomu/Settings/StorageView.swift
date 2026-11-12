import AppCommon
import Core
import KavitaKit
import SwiftUI

/// Settings ▸ Storage ▸ Downloads: volumes downloading and on the device, by series, so
/// everything downloaded is visible and removable.
struct DownloadedVolumesView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var confirmsDelete: DownloadGroup?

    private var downloader: VolumeDownloader { environment.downloader }
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
                DownloadsEmptySection("Download volumes from a series to read them offline. Nothing downloads unless you ask.")
            }
            if !active.isEmpty {
                Section("Downloading") {
                    ForEach(active) { record in
                        let activity = record.id.flatMap { downloader.activity[$0] }
                        DownloadRow(record: record.withSeriesInDetail.markingAutomatic, waitingReason: downloader.waitingReason,
                                    activity: activity?.text, activityFraction: activity?.fraction,
                                    onPause: { downloader.pause(record) },
                                    onResume: { downloader.resume(record) },
                                    onDelete: { Task { await downloader.delete(record) } })
                    }
                }
            }
            ForEach(groups) { group in
                Section {
                    ForEach(group.downloads) { record in
                        let activity = record.id.flatMap { downloader.activity[$0] }
                        DownloadRow(record: record.markingAutomatic,
                                    activity: activity?.text ?? (VolumeDownloader.extra(record)?.textPending == true ? "Waiting to read text" : nil),
                                    activityFraction: activity?.fraction,
                                    onPause: {}, onResume: {},
                                    onDelete: { Task { await downloader.delete(record) } })
                    }
                } header: {
                    header(group)
                }
            }
        }
        .navigationTitle("Downloads")
        .navigationDestination(for: KavitaSeries.self) { series in
            SeriesDetailView(series: series)
        }
        .confirmationDialog("Remove every downloaded volume of \(confirmsDelete?.seriesTitle ?? "")?",
                            isPresented: Binding(get: { confirmsDelete != nil }, set: { if !$0 { confirmsDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Remove \(confirmsDelete?.downloads.count ?? 0) Downloads", role: .destructive) {
                let records = confirmsDelete?.downloads ?? []
                Task { for record in records { await downloader.delete(record) } }
            }
        }
    }

    private func header(_ group: DownloadGroup) -> some View {
        HStack {
            if let id = group.seriesKey.flatMap(Int.init), let series = try? environment.kavitaLibrary.cachedSeries(id: id) {
                NavigationLink(value: series) {
                    Text(group.seriesTitle)
                }
            } else {
                Text(group.seriesTitle)
            }
            Spacer()
            Text(group.bytes.storageText)
            Menu {
                Button("Remove All", systemImage: "trash", role: .destructive) { confirmsDelete = group }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuIndicator(.hidden)
            .buttonStyle(.borderless)
        }
    }
}

extension DownloadRecord {
    /// Automatic downloads say so in their detail line.
    fileprivate var markingAutomatic: DownloadRecord {
        guard VolumeDownloader.extra(self)?.isAutomatic == true else { return self }
        var record = self
        record.detail = [detail, "Automatic"].compactMap(\.self).filter { !$0.isEmpty }.joined(separator: " · ")
        return record
    }
}
