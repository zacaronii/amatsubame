import Core
import Dictionary
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// The pieces every app's Settings is built from, in one order:
// the status card, the app's own section, Lookup and Mining, Stats, then Storage, Advanced
// and About.

/// A row's icon: a symbol on a rounded colour square, like the system Settings.
public struct SettingsIcon: View {
    let systemName: String
    let color: Color

    public init(_ systemName: String, color: Color) {
        self.systemName = systemName
        self.color = color
    }

    public var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: 29, height: 29)
            .background(color.gradient, in: .rect(cornerRadius: 7))
            .accessibilityHidden(true)
    }
}

/// A Settings row: icon, title (with a status dot), and a line under it or a value beside it.
public struct SettingsRowLabel: View {
    let title: String
    let subtitle: String?
    let value: String?
    let systemImage: String
    let color: Color
    let dot: Color?

    public init(_ title: String, subtitle: String? = nil, value: String? = nil, systemImage: String, color: Color, dot: Color? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.value = value
        self.systemImage = systemImage
        self.color = color
        self.dot = dot
    }

    public var body: some View {
        HStack(spacing: 12) {
            SettingsIcon(systemImage, color: color)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if let dot { Circle().fill(dot).frame(width: 8, height: 8).accessibilityHidden(true) }
                    Text(title)
                }
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            if let value {
                Spacer(minLength: 8)
                Text(value).foregroundStyle(.secondary)
            }
        }
    }
}

public extension ServerAccount {
    /// "kavita.example.ts.net · reader": where it is and who's signed in.
    var hostAndAccount: String {
        [baseURL.host(percentEncoded: false) ?? baseURL.absoluteString, username].compactMap { $0 }.joined(separator: " · ")
    }

    /// Green once tested, orange if never tested.
    var dotColor: Color { serverVersion == nil ? .orange : .green }
}

// MARK: Status card

/// One chip in the status card: a server (or feature) and how to check it, read-only.
public struct StatusItem: Identifiable {
    public let name: String
    public let isSetUp: Bool
    let check: () async throws -> Void
    public var id: String { name }

    public init(_ name: String, isSetUp: Bool, check: @escaping () async throws -> Void) {
        self.name = name
        self.isSetUp = isSetUp
        self.check = check
    }
}

/// The result of each chip's check, kept while the app runs (a minute before checking again).
@Observable
final class ServerStatusModel {
    enum State: Equatable { case checking, ok, failed(String) }
    private(set) var states: [String: State] = [:]
    @ObservationIgnored private var checkedAt: [String: Date] = [:]

    func refresh(_ items: [StatusItem], force: Bool = false) async {
        let due = items.filter { item in
            guard item.isSetUp else { return false }
            if !force, let date = checkedAt[item.name], Date().timeIntervalSince(date) < 60, states[item.name] != nil { return false }
            return true
        }
        // All at once; each chip updates when its own check ends.
        let checks = due.map { item in
            if states[item.name] == nil { states[item.name] = .checking }
            return Task {
                do {
                    try await item.check()
                    states[item.name] = .ok
                } catch {
                    guard !error.isCancellation else { return }
                    states[item.name] = .failed(error.localizedDescription)
                    AppLog.error(.servers, "\(item.name): \(error.localizedDescription)")
                }
                checkedAt[item.name] = Date()
            }
        }
        for check in checks { await check.value }
    }
}

/// The top of Settings: one chip per server with a dot, what's waiting to sync with Sync Now,
/// and any startup error. Servers that aren't set up are greyed, never red.
public struct SettingsStatusCard: View {
    @Environment(CommonEnvironment.self) private var environment
    @State private var model = ServerStatusModel()
    @State private var waiting: [OutboxJobKind: Int] = [:]
    let items: [StatusItem]

    public init(items: [StatusItem]) {
        self.items = items
    }

    public var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                if let error = environment.startupError {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }
                Label(headline, systemImage: headlineSymbol)
                    .font(.headline)
                    .foregroundStyle(failing.isEmpty ? .primary : Color.orange)
                    .accessibilityIdentifier("status.headline")
                ChipFlow(spacing: 6) {
                    ForEach(items) { item in chip(item) }
                }
            }
            .padding(.vertical, 4)
            if !waitingText.isEmpty {
                HStack {
                    Text("Waiting to sync: \(waitingText)").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Sync Now") { environment.syncNow(retryWaiting: true) }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("status.syncNow")
                }
            }
        }
        .task { await model.refresh(items) }
        .task {
            do {
                for try await counts in environment.outbox.observeWaitingCounts() { waiting = counts }
            } catch {}
        }
    }

    private var failing: [String] {
        items.filter { if case .failed = model.states[$0.name] { true } else { false } }.map(\.name)
    }

    private var headline: String {
        if !failing.isEmpty { return "Can't reach \(failing.formatted(.list(type: .and)))" }
        let setUp = items.filter(\.isSetUp)
        if setUp.isEmpty { return "Nothing connected yet" }
        if setUp.contains(where: { model.states[$0.name] == nil || model.states[$0.name] == .checking }) { return "Checking…" }
        return setUp.count == items.count ? "Everything is connected" : "Connected"
    }

    private var headlineSymbol: String {
        failing.isEmpty ? "checkmark" : "exclamationmark.triangle.fill"
    }

    private var waitingText: String {
        OutboxJobKind.allCases.compactMap { kind in waiting[kind].map { kind.waitingCount($0) } }.formatted(.list(type: .and))
    }

    private func chip(_ item: StatusItem) -> some View {
        let state = model.states[item.name]
        let color: Color = switch state {
        case _ where !item.isSetUp: .secondary.opacity(0.4)
        case .ok: .green
        case .failed: .orange
        case .checking, nil: .secondary
        }
        return HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(item.name).font(.subheadline)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.fill.tertiary, in: .capsule)
        .opacity(item.isSetUp ? 1 : 0.55)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("status.\(item.name)")
        .accessibilityValue(chipValue(item, state: state))
    }

    private func chipValue(_ item: StatusItem, state: ServerStatusModel.State?) -> String {
        guard item.isSetUp else { return "not set up" }
        return switch state {
        case .ok: "connected"
        case .failed(let message): "can't reach: \(message)"
        case .checking, nil: "checking"
        }
    }
}

/// Chips that wrap onto more lines.
struct ChipFlow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(width: bounds.width, subviews: subviews)
        for row in rows {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row { var indices: [Int] = []; var y: CGFloat = 0; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            if !rows[rows.count - 1].indices.isEmpty, rows[rows.count - 1].width + spacing + size.width > width {
                let last = rows[rows.count - 1]
                rows.append(Row(y: last.y + last.height + spacing))
            }
            var row = rows[rows.count - 1]
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows
    }
}

// MARK: Lookup and Mining

/// Dictionaries, Audio Sources, Anki and word marks: the same in every app, and shared
/// between them when sharing is on. `ankiPage`: the app's Anki page (Miru adds Card Picture).
public struct LookupAndMiningSection<AnkiPage: View>: View {
    @Environment(CommonEnvironment.self) private var environment
    @State private var dictionaries: [DictionaryRecord] = []
    @State private var sourceCount = 0
    @State private var deck: String?
    let footnote: String?
    let ankiPage: () -> AnkiPage

    /// `footnote`: what the word marks cover in this app.
    public init(footnote: String? = nil, @ViewBuilder ankiPage: @escaping () -> AnkiPage) {
        self.footnote = footnote
        self.ankiPage = ankiPage
    }

    public var body: some View {
        Section {
            NavigationLink {
                DictionariesView()
            } label: {
                SettingsRowLabel("Dictionaries", subtitle: dictionarySummary, systemImage: "character.book.closed.ja", color: .purple)
            }
            .accessibilityIdentifier("settings.dictionaries")
            NavigationLink {
                AudioSourcesView()
            } label: {
                SettingsRowLabel("Audio Sources", subtitle: sourceCount == 1 ? "1 source" : "\(sourceCount) sources",
                                 systemImage: "speaker.wave.2.fill", color: .pink)
            }
            .accessibilityIdentifier("settings.audioSources")
            NavigationLink {
                ankiPage()
            } label: {
                SettingsRowLabel("Anki", subtitle: ankiSummary, systemImage: "rectangle.stack.fill", color: .green,
                                 dot: environment.serverAccounts[.anki]?.dotColor)
            }
            .accessibilityIdentifier("settings.anki")
            WordMarksToggle()
        } header: {
            Text("Lookup and Mining")
        } footer: {
            Text(footer)
        }
        .task {
            do {
                for try await records in environment.dictionaries.observeDictionaries() { dictionaries = records }
            } catch {}
        }
        .onAppear {
            sourceCount = ((try? environment.lookup.audio.sources()) ?? []).filter(\.enabled).count
            deck = (try? environment.ankiSettings.settings())?.deck
        }
    }

    private var dictionarySummary: String {
        let enabled = dictionaries.filter(\.enabled)
        if enabled.isEmpty { return dictionaries.isEmpty ? "None yet" : "All turned off" }
        return enabled.map { record in RecommendedDictionaries.all.first { $0.matches(record) }?.name ?? record.title }
            .joined(separator: ", ")
    }

    private var ankiSummary: String {
        guard environment.serverAccounts[.anki] != nil else { return "Not set up" }
        let settings = try? environment.ankiSettings.settings()
        return ["Connected", settings.map { "Deck: \($0.deck)" }, settings?.noteType].compactMap { $0 }.joined(separator: " · ")
    }

    private var footer: String {
        var parts: [String] = []
        let others = environment.appsSharingSetup
        if !others.isEmpty {
            parts.append("Shared with \(others.formatted(.list(type: .and))). \(others.count == 1 ? "A change here shows there too." : "A change here shows in all of them.")")
        }
        parts.append(WordMarksToggle.footer + (footnote.map { " \($0)" } ?? ""))
        return parts.joined(separator: " ")
    }
}

// MARK: Stats

/// Settings ▸ Stats: kechimochi.
public struct StatsSettingsLink: View {
    @Environment(CommonEnvironment.self) private var environment
    @State private var address: String?

    public init() {}

    public var body: some View {
        Section("Stats") {
            NavigationLink {
                Form { StatsSettingsSection() }
                    .formStyle(.grouped)
                    .navigationTitle("kechimochi")
            } label: {
                SettingsRowLabel("kechimochi", subtitle: address == nil ? "Not set up" : "Connected · links from the Stats tab",
                                 systemImage: "chart.bar.fill", color: .orange)
            }
            .accessibilityIdentifier("settings.kechimochi")
        }
        .onAppear { address = (try? environment.activity.kechimochiURL()) ?? nil }
    }
}

// MARK: Storage, Advanced, About

/// The last group: Storage (with its total), Advanced and About.
public struct SettingsFooterSection<Storage: View, Advanced: View, About: View>: View {
    let storageTotal: String?
    let storage: () -> Storage
    let advanced: () -> Advanced
    let about: () -> About

    public init(storageTotal: String?, @ViewBuilder storage: @escaping () -> Storage,
                @ViewBuilder advanced: @escaping () -> Advanced, @ViewBuilder about: @escaping () -> About) {
        self.storageTotal = storageTotal
        self.storage = storage
        self.advanced = advanced
        self.about = about
    }

    public var body: some View {
        Section {
            NavigationLink(destination: storage) {
                SettingsRowLabel("Storage", value: storageTotal, systemImage: "internaldrive.fill", color: .gray)
            }
            .accessibilityIdentifier("settings.storage")
            NavigationLink(destination: advanced) {
                SettingsRowLabel("Advanced", systemImage: "wrench.and.screwdriver.fill", color: .gray)
            }
            .accessibilityIdentifier("settings.advanced")
            NavigationLink(destination: about) {
                SettingsRowLabel("About", value: "\(CommonEnvironment.appVersion) (\(CommonEnvironment.buildNumber))",
                                 systemImage: "info", color: .blue)
            }
            .accessibilityIdentifier("settings.about")
        }
    }
}

/// Settings ▸ Advanced: the shared setup, what's waiting to sync, Run Setup Again, and
/// troubleshooting. `kinds`: what this app sends. `troubleshooting`: the app's own rows.
public struct AdvancedSettingsView<Troubleshooting: View>: View {
    @Environment(CommonEnvironment.self) private var environment
    @State private var waiting: [OutboxJobKind: Int] = [:]
    @State private var logFile: URL?
    let kinds: [OutboxJobKind]
    let extraLogs: [URL]
    let troubleshooting: Troubleshooting

    public init(kinds: [OutboxJobKind], extraLogs: [URL] = [], @ViewBuilder troubleshooting: () -> Troubleshooting = { EmptyView() }) {
        self.kinds = kinds
        self.extraLogs = extraLogs
        self.troubleshooting = troubleshooting()
    }

    public var body: some View {
        Form {
            SetupSharingSection()
            Section {
                ForEach(kinds, id: \.self) { kind in
                    NavigationLink {
                        OutboxView(kind: kind)
                    } label: {
                        LabeledContent(kind.waitingTitle, value: waiting[kind].map { "\($0) waiting" } ?? "None")
                    }
                    .accessibilityIdentifier("advanced.waiting.\(kind.rawValue)")
                }
                Button("Sync Now") { environment.syncNow(retryWaiting: true) }
                    .accessibilityIdentifier("advanced.syncNow")
            } header: {
                Text("Waiting to Sync")
            } footer: {
                Text("Things saved while a server was out of reach. They send on their own when it's back; tap one to see or clear it.")
            }
            Section {
                Button("Run Setup Again") { environment.setup.runAgain() }
                    .accessibilityIdentifier("advanced.runSetup")
            } footer: {
                Text("Walks through the first-launch setup. Nothing is deleted.")
            }
            Section("Troubleshooting") {
                troubleshooting
                if let logFile {
                    ShareLink(item: logFile) {
                        Label("Export Logs", systemImage: "square.and.arrow.up")
                    }
                    .accessibilityIdentifier("advanced.exportLogs")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Advanced")
        .task {
            do {
                for try await counts in environment.outbox.observeWaitingCounts() { waiting = counts }
            } catch {}
        }
        .onAppear { logFile = AppLog.export(appName: CommonEnvironment.appName, extra: extraLogs) }
    }
}

/// Settings ▸ Storage's top: the app's total, a bar by kind, and a legend.
public struct StorageSummary: View {
    public struct Part: Identifiable {
        public let name: String
        public let bytes: Int64
        public let color: Color
        public var id: String { name }

        public init(_ name: String, bytes: Int64, color: Color) {
            self.name = name
            self.bytes = bytes
            self.color = color
        }
    }

    let parts: [Part]

    public init(parts: [Part]) {
        self.parts = parts
    }

    public var body: some View {
        let total = parts.reduce(0) { $0 + $1.bytes }
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(CommonEnvironment.appName) on this \(Self.deviceName)").font(.headline)
                Spacer()
                Text(total.storageText).foregroundStyle(.secondary)
            }
            GeometryReader { geometry in
                HStack(spacing: 2) {
                    ForEach(parts.filter { $0.bytes > 0 }) { part in
                        part.color.frame(width: max(3, geometry.size.width * CGFloat(part.bytes) / CGFloat(max(total, 1)) - 2))
                    }
                }
                .clipShape(.capsule)
            }
            .frame(height: 8)
            HStack(spacing: 12) {
                ForEach(parts) { Text($0.name).font(.caption).foregroundStyle(.secondary) }
            }
            if let free = DownloadStorageHeader.freeSpace() {
                Text("\(free.formatted(.byteCount(style: .file))) free on this \(Self.deviceName)").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("storage.summary")
    }

    static var deviceName: String {
        #if os(macOS)
        "Mac"
        #else
        UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        #endif
    }
}

public extension DictionaryLibrary {
    /// What the installed dictionaries take up.
    func totalBytes() -> Int64 {
        Int64(((try? dictionaries()) ?? []).reduce(0) { $0 + $1.bytes })
    }
}
