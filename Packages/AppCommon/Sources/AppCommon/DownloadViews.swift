import Core
import SwiftUI

/// The download control on a volume or episode row: download, progress (tap to stop),
/// or downloaded (its menu removes it).
public struct DownloadButton: View {
    let record: DownloadRecord?
    let onDownload: () -> Void
    let onCancel: () -> Void
    let onDelete: () -> Void

    public init(record: DownloadRecord?, onDownload: @escaping () -> Void, onCancel: @escaping () -> Void,
                onDelete: @escaping () -> Void) {
        self.record = record
        self.onDownload = onDownload
        self.onCancel = onCancel
        self.onDelete = onDelete
    }

    public var body: some View {
        Group {
            switch record?.state {
            case nil:
                Button(action: onDownload) {
                    Image(systemName: "arrow.down.circle")
                }
                .accessibilityLabel("Download")
            case .queued?:
                Button(action: onCancel) {
                    Image(systemName: "clock")
                }
                .accessibilityLabel("Waiting to download; cancel")
            case .downloading?:
                Button(action: onCancel) {
                    ZStack {
                        ProgressRing(fraction: record?.fraction ?? 0)
                        Image(systemName: "stop.fill").font(.system(size: 7))
                    }
                    .frame(width: 20, height: 20)
                }
                .accessibilityLabel("Downloading \(Int((record?.fraction ?? 0) * 100))%; stop")
            case .paused?, .failed?:
                Button(action: onDownload) {
                    Image(systemName: record?.state == .failed ? "exclamationmark.arrow.circlepath" : "arrow.clockwise.circle")
                }
                .accessibilityLabel(record?.state == .failed ? "Download failed; retry" : "Paused; resume")
            case .done?:
                Menu {
                    Button("Delete Download", systemImage: "trash", role: .destructive, action: onDelete)
                } label: {
                    // Grey, so it reads as a state, not a button to press.
                    Image(systemName: "arrow.down.circle.fill").foregroundStyle(.secondary)
                }
                .menuIndicator(.hidden)
                .accessibilityLabel("Downloaded")
            }
        }
        .font(.title3)
        .buttonStyle(.borderless)
        .foregroundStyle(.tint)
        .accessibilityIdentifier("download.button")
    }
}

extension BinaryInteger {
    /// A size for storage screens: "None" when empty (the byte-count style says "Zero kB").
    public var storageText: String {
        self == 0 ? "None" : Int64(self).formatted(.byteCount(style: .file))
    }
}

/// A circular progress indicator.
public struct ProgressRing: View {
    let fraction: Double

    public init(fraction: Double) {
        self.fraction = fraction
    }

    public var body: some View {
        ZStack {
            Circle().stroke(.tint.opacity(0.25), lineWidth: 2)
            Circle().trim(from: 0, to: max(fraction, 0.02)).stroke(.tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

/// One download in Settings ▸ Storage: what it is, its state and size, and swipe actions.
public struct DownloadRow: View {
    let record: DownloadRecord
    /// Shown for a queued download when the network rule is holding it back.
    var waitingReason: String?
    /// What the download is doing: transferring ("Pages 12 of 180") or, once done, a follow-up
    /// step ("Reading text 12 of 180"), with how far along it is.
    var activity: String?
    var activityFraction: Double?
    let onPause: () -> Void
    let onResume: () -> Void
    let onDelete: () -> Void

    public init(record: DownloadRecord, waitingReason: String? = nil, activity: String? = nil, activityFraction: Double? = nil,
                onPause: @escaping () -> Void, onResume: @escaping () -> Void, onDelete: @escaping () -> Void) {
        self.record = record
        self.waitingReason = waitingReason
        self.activity = activity
        self.activityFraction = activityFraction
        self.onPause = onPause
        self.onResume = onResume
        self.onDelete = onDelete
    }

    public var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(record.title).lineLimit(1)
                if let detail = record.detail, !detail.isEmpty {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Text(status)
                    .font(.caption)
                    .foregroundStyle(record.state == .failed ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .lineLimit(2)
                if record.state == .done, let activity {
                    Text(activity).font(.caption).foregroundStyle(.secondary)
                }
                if record.state == .downloading || (record.state == .done && activityFraction != nil) {
                    ProgressView(value: activityFraction ?? record.fraction ?? 0)
                }
            }
            Spacer(minLength: 0)
            switch record.state {
            case .downloading, .queued:
                Button("Pause", systemImage: "pause.circle", action: onPause).labelStyle(.iconOnly)
            case .paused, .failed:
                Button("Resume", systemImage: "arrow.clockwise.circle", action: onResume).labelStyle(.iconOnly)
            case .done:
                EmptyView()
            }
        }
        .font(.body)
        .buttonStyle(.borderless)
        .contextMenu {
            Button("Delete Download", systemImage: "trash", role: .destructive, action: onDelete)
        }
        .swipeActions {
            Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
        }
        .accessibilityIdentifier("downloads.row")
    }

    private var status: String {
        let done = record.bytesDone.formatted(.byteCount(style: .file))
        let total = record.bytesTotal?.formatted(.byteCount(style: .file))
        switch record.state {
        case .queued: return waitingReason ?? "Waiting to download"
        case .downloading: return activity ?? (total.map { "\(done) of \($0)" } ?? done)
        case .paused: return "Paused · " + (total.map { "\(done) of \($0)" } ?? done)
        case .done:
            let size = (record.bytesTotal ?? record.bytesDone).formatted(.byteCount(style: .file))
            return activity == nil ? size : "Downloaded · \(size)"
        case .failed: return record.error ?? "Failed"
        }
    }
}

/// Space used by downloads and what's left on the device.
public struct DownloadStorageHeader: View {
    let used: Int64

    public init(used: Int64) {
        self.used = used
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent("Downloads", value: used.storageText)
            if let free = Self.freeSpace() {
                LabeledContent("Free on this device", value: free.formatted(.byteCount(style: .file)))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("downloads.storage")
    }

    static func freeSpace() -> Int64? {
        let values = try? URL.applicationSupportDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}

/// Settings → Downloads: the network rule (and app-specific extras below it).
public struct DownloadSettingsSection<Extra: View>: View {
    @Environment(CommonEnvironment.self) private var environment
    @State private var settings = DownloadSettings()
    let extra: (Binding<DownloadSettings>) -> Extra

    public init(@ViewBuilder extra: @escaping (Binding<DownloadSettings>) -> Extra) {
        self.extra = extra
    }

    public var body: some View {
        Section {
            Toggle("Download over Cellular", isOn: binding(\.allowsCellular))
                .accessibilityIdentifier("downloads.cellular")
            extra(Binding(get: { settings }, set: { settings = $0; try? $0.save(environment.database) }))
        } header: {
            Text("Downloads")
        }
        .onAppear { settings = DownloadSettings.load(environment.database) }
    }

    private func binding(_ keyPath: WritableKeyPath<DownloadSettings, Bool>) -> Binding<Bool> {
        Binding {
            settings[keyPath: keyPath]
        } set: { value in
            settings[keyPath: keyPath] = value
            try? settings.save(environment.database)
        }
    }
}

extension DownloadSettingsSection where Extra == EmptyView {
    public init() {
        self.init { _ in EmptyView() }
    }
}

extension DownloadRecord {
    /// For lists not grouped by series (in progress): "Series · detail".
    public var withSeriesInDetail: DownloadRecord {
        var record = self
        record.detail = [seriesTitle, detail].compactMap(\.self).filter { !$0.isEmpty }.joined(separator: " · ")
        return record
    }
}

/// Shown in Settings ▸ Storage while nothing is downloaded (a row, so it never covers other sections).
public struct DownloadsEmptySection: View {
    let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var body: some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text("No downloads yet").font(.headline)
                    Text(message).font(.subheadline).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "arrow.down.circle").foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("downloads.empty")
        }
    }
}
