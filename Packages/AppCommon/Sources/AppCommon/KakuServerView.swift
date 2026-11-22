import AudiobookshelfKit
import Core
import Foundation
import Observation
import SwiftUI

/// What Kaku is doing, read from its API every few seconds while Settings ▸ Kaku is open (#149):
/// the job running, the queue, failures (with Try Again), each library (with switches for which
/// ones it transcribes) and the server.
@MainActor @Observable
final class KakuServerModel {
    private(set) var health: KakuHealth?
    private(set) var queue: KakuQueue?
    private(set) var libraries: KakuLibraries?
    private(set) var error: String?
    /// A library switch or Try Again on its way.
    private(set) var busy: Set<String> = []

    @ObservationIgnored private let common: CommonEnvironment

    init(common: CommonEnvironment) {
        self.common = common
    }

    private var client: KakuClient? { AudioServers.kakuClient(common) }

    /// Forgets what a server that's been removed said.
    func clear() {
        (health, queue, libraries, error) = (nil, nil, nil, nil)
    }

    /// Every 5 seconds until the screen goes.
    func follow() async {
        while !Task.isCancelled {
            await load()
            try? await Task.sleep(for: .seconds(5))
        }
    }

    func load() async {
        guard let client else { return }
        do {
            async let health = client.health()
            async let queue = client.queue(limit: 8)
            async let libraries = client.libraries()
            (self.health, self.queue, self.libraries) = try await (health, queue, libraries)
            error = nil
        } catch let failure {
            if !failure.isCancellation { error = failure.localizedDescription }
        }
    }

    func setEnabled(_ library: KakuLibrary, _ on: Bool) async {
        guard let client, let libraries else { return }
        var enabled = Set(libraries.libraries.filter(\.enabled).map(\.id))
        if on { enabled.insert(library.id) } else { enabled.remove(library.id) }
        busy.insert(library.id)
        defer { busy.remove(library.id) }
        do {
            self.libraries = try await client.setLibraries(enabled: enabled.sorted())
        } catch let failure {
            error = failure.localizedDescription
        }
    }

    func retry(_ job: KakuQueueJob) async {
        guard let client else { return }
        busy.insert(job.id)
        defer { busy.remove(job.id) }
        do {
            try await client.retry(job)
            await load()
        } catch let failure {
            error = failure.localizedDescription
        }
    }

    /// "Podcasts", or "Jellyfin" for Miru's episodes.
    func libraryName(_ id: String) -> String? {
        id == "jellyfin" ? "Jellyfin" : libraries?.libraries.first { $0.id == id }?.name
    }
}

/// What Kaku is doing, as the sections of the Kaku screen: what's running, the queue, failures,
/// each library, then the server itself. `KakuSettingsView` runs the model.
struct KakuServerSections: View {
    let model: KakuServerModel

    var body: some View {
        if let error = model.error {
            Section {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
        }
        if let queue = model.queue {
            running(queue)
            waiting(queue)
            if !queue.failed.isEmpty { problems(queue.failed) }
        } else if model.error == nil {
            Section {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Asking Kaku…").foregroundStyle(.secondary)
                }
            }
        }
        if let libraries = model.libraries { librarySection(libraries) }
        if let health = model.health { server(health) }
    }

    // MARK: Sections

    private func server(_ health: KakuHealth) -> some View {
        Section("Server") {
            LabeledContent("Version", value: health.version)
            if let name = health.model {
                LabeledContent("Model") {
                    Text(health.modelLoaded == true ? "\(name) · loaded" : "\(name) · not loaded")
                }
            }
            if let gpu = health.gpu {
                LabeledContent("GPU Memory", value: "\(Self.gigabytes(gpu.usedMB)) of \(Self.gigabytes(gpu.totalMB)) in use")
            }
            if let lastPoll = health.lastPoll {
                LabeledContent("Checked Audiobookshelf", value: Self.ago(lastPoll))
            }
            if let error = health.lastPollError {
                Label(error, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
            }
        }
    }

    private func running(_ queue: KakuQueue) -> some View {
        Section("Now Transcribing") {
            if let job = queue.running {
                VStack(alignment: .leading, spacing: 6) {
                    jobTitle(job)
                    ProgressView(value: job.progress ?? 0)
                    Text("\(Int(((job.progress ?? 0) * 100).rounded()))%").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            } else {
                Text("Nothing: Kaku is idle.").foregroundStyle(.secondary)
            }
        }
    }

    private func waiting(_ queue: KakuQueue) -> some View {
        Section {
            if queue.queued.isEmpty {
                Text("Everything is transcribed.").foregroundStyle(.secondary)
            }
            ForEach(queue.queued) { job in
                HStack(alignment: .firstTextBaseline) {
                    jobTitle(job)
                    Spacer(minLength: 8)
                    Text(Self.priorityText(job.priority)).font(.caption).foregroundStyle(.secondary)
                }
            }
            let more = queue.queuedCount - queue.queued.count
            if more > 0 {
                Text("and \(more) more").font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("Queue (\(queue.queuedCount))")
        } footer: {
            if let estimate = queue.estimatedSeconds, let average = queue.averageSeconds {
                Text("About \(Self.length(estimate)) to go, at about \(Self.length(average)) each lately. Asked for comes first, then what's new this week, then the rest, newest first.")
            } else {
                Text("Asked for comes first, then what's new this week, then the rest, newest first.")
            }
        }
    }

    private func problems(_ failed: [KakuQueueJob]) -> some View {
        Section {
            ForEach(failed) { job in
                VStack(alignment: .leading, spacing: 4) {
                    jobTitle(job)
                    if let error = job.error {
                        Text(error).font(.footnote).foregroundStyle(.orange)
                    }
                    Button("Try Again") { Task { await model.retry(job) } }
                        .font(.footnote)
                        .disabled(model.busy.contains(job.id))
                }
            }
        } header: {
            Text("Problems")
        } footer: {
            Text("Kaku tries a failed job twice more on its own, then waits for Try Again.")
        }
    }

    private func librarySection(_ libraries: KakuLibraries) -> some View {
        Section {
            ForEach(libraries.libraries) { library in
                Toggle(isOn: Binding(get: { library.enabled }, set: { on in Task { await model.setEnabled(library, on) } })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(library.name)
                        Text(Self.detail(library.enabled ? library.progress : nil, kind: library.mediaType == .book ? ("book", "books") : ("episode", "episodes"),
                                         enabled: library.enabled))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(model.busy.contains(library.id))
            }
            if let jellyfin = libraries.jellyfin {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Jellyfin")
                    Text(Self.detail(jellyfin, kind: ("episode asked for in Miru", "episodes asked for in Miru"), enabled: true)).font(.footnote).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Libraries")
        } footer: {
            Text("Kaku transcribes the Audiobookshelf libraries switched on, new episodes first. Switch on only Japanese ones.")
        }
    }

    // MARK: Pieces

    private func jobTitle(_ job: KakuQueueJob) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(job.title).lineLimit(2)
            if let library = model.libraryName(job.libraryId) {
                Text(library).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// "120 of 131 episodes transcribed · 10 waiting · 1 failed · updated 2 hours ago".
    static func detail(_ progress: KakuLibraryProgress?, kind: (one: String, many: String), enabled: Bool) -> String {
        guard enabled else { return "Off" }
        guard let progress else { return "On" }
        let counts = progress.counts
        var parts = ["\(counts.done) of \(counts.total) \(counts.total == 1 ? kind.one : kind.many) transcribed"]
        if counts.queued + counts.running > 0 { parts.append("\(counts.queued + counts.running) waiting") }
        if counts.failed > 0 { parts.append("\(counts.failed) failed") }
        if let last = progress.lastTranscribed { parts.append("updated \(ago(last))") }
        return parts.joined(separator: " · ")
    }

    static func priorityText(_ priority: String?) -> String {
        switch priority {
        case "now": "Asked for"
        case "new": "New"
        default: "Backlog"
        }
    }

    static func gigabytes(_ megabytes: Int) -> String {
        String(format: "%.1f GB", Double(megabytes) / 1024)
    }

    /// "2 h 10 min", "4 min".
    static func length(_ seconds: Double) -> String {
        Duration.seconds(max(seconds, 60)).formatted(.units(allowed: [.days, .hours, .minutes], width: .abbreviated, maximumUnitCount: 2))
    }

    static func ago(_ seconds: Double) -> String {
        Date(timeIntervalSince1970: seconds).formatted(.relative(presentation: .named))
    }
}

/// Kaku's row in each app's Settings: its name, and in a few words what it's doing ("Idle · 155
/// transcribed"), asked once when the list shows.
public struct KakuSettingsRow: View {
    @Environment(CommonEnvironment.self) private var common
    @State private var health: KakuHealth?
    @State private var unreachable = false
    let purpose: String

    /// `purpose`: what Kaku is for in this app, shown until it's set up ("Transcripts").
    public init(purpose: String) {
        self.purpose = purpose
    }

    public var body: some View {
        let account = common.serverAccounts[.kaku]
        SettingsRowLabel("Kaku", subtitle: Self.summary(purpose: purpose, host: account?.baseURL.host(), health: health, unreachable: unreachable),
                         systemImage: "text.quote", color: .teal, dot: account == nil ? nil : unreachable ? .red : account?.dotColor)
            .task(id: account?.baseURL) {
                (health, unreachable) = (nil, false)
                guard let client = AudioServers.kakuClient(common) else { return }
                do {
                    health = try await client.health()
                } catch {
                    unreachable = !error.isCancellation
                }
            }
    }

    static func summary(purpose: String, host: String?, health: KakuHealth?, unreachable: Bool) -> String {
        guard let host else { return "\(purpose) · not set up" }
        if unreachable { return "Can't reach \(host)" }
        guard let jobs = health?.jobs else { return host }
        let waiting = jobs["queued"] ?? 0
        let failed = jobs["failed"] ?? 0
        var parts: [String] = []
        if (jobs["running"] ?? 0) > 0 || waiting > 0 {
            parts.append(waiting > 0 ? "Transcribing · \(waiting) waiting" : "Transcribing")
        } else {
            parts.append("Idle · \(jobs["done"] ?? 0) transcribed")
        }
        if failed > 0 { parts.append("\(failed) failed") }
        return parts.joined(separator: " · ")
    }
}
