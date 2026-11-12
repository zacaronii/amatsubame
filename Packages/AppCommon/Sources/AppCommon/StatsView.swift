import Anki
import Charts
import Core
import Observation
import SwiftUI

/// The Stats tab's data: this app's reading or watching log and lookups, and cards mined
/// (every app's, from the mining deck in Anki, plus this app's cards not sent yet).
@MainActor @Observable
public final class StatsModel {
    public var period = StatsSummary.Period.week {
        didSet { summarize() }
    }
    public private(set) var summary: StatsSummary?
    @ObservationIgnored private let kind: ActivitySession.Kind
    @ObservationIgnored private let environment: CommonEnvironment
    @ObservationIgnored private var sessions: [ActivitySession] = []
    @ObservationIgnored private var lookups: [Date] = []
    @ObservationIgnored private var ankiCards: [Date] = []
    @ObservationIgnored private var unsentCards: [Date] = []
    @ObservationIgnored private var ownCards: [MinedCardStat] = []

    public init(kind: ActivitySession.Kind, environment: CommonEnvironment) {
        self.kind = kind
        self.environment = environment
    }

    /// Reads the local log at once, then asks Anki for the mining deck's cards (cached for offline).
    public func load() async {
        let activity = environment.activity
        sessions = (try? activity.sessions(kind: kind)) ?? []
        lookups = (try? activity.lookupDates()) ?? []
        loadOwnCards()
        ankiCards = Self.dates(noteIds: (try? activity.cachedAnkiNoteIds()) ?? [])
        summarize()
        guard let ids = await Self.refreshDeck(environment) else { return }
        ankiCards = Self.dates(noteIds: ids)
        summarize()
    }

    /// Asks Anki for the mining deck's notes and keeps the copy that Stats and the Today rows
    /// read offline. Nil without AnkiConnect.
    @discardableResult
    public static func refreshDeck(_ environment: CommonEnvironment) async -> [Int64]? {
        guard let client = environment.ankiClient(), let deck = try? environment.ankiSettings.settings().deck else { return nil }
        let escaped = deck.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        guard let ids = try? await client.findNotes("deck:\"\(escaped)\"") else { return nil }
        try? environment.activity.saveAnkiNoteIds(ids)
        return ids
    }

    /// Anki note ids are their creation times in milliseconds.
    static func dates(noteIds: [Int64]) -> [Date] {
        noteIds.map { Date(timeIntervalSince1970: Double($0) / 1000) }
    }

    private func loadOwnCards() {
        let jobs = ((try? environment.outbox.jobs(states: [.pending, .inFlight, .sent, .failed])) ?? []).filter { $0.kind == .ankiNote }
        unsentCards = jobs.filter { $0.state != .sent }.map(\.createdAt)
        ownCards = jobs.compactMap { job in
            guard let card = try? job.decodePayload(MinedCard.self) else { return nil }
            return MinedCardStat(date: job.createdAt, seriesKey: card.seriesKey,
                                 seriesTitle: card.seriesTitle ?? Self.title(miscInfo: card.content[.miscInfo]))
        }
    }

    /// The series in a card's source ("鉄の時計 — Volume 1, p. 9"), for cards from before Stats.
    static func title(miscInfo: String?) -> String? {
        guard let miscInfo, let range = miscInfo.range(of: " — ") else { return nil }
        let title = String(miscInfo[..<range.lowerBound])
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
        return title.isEmpty ? nil : title
    }

    private func summarize() {
        summary = StatsSummary.make(kind: kind, period: period, sessions: sessions, lookups: lookups,
                                    cards: ankiCards + unsentCards, ownCards: ownCards)
    }
}

/// The Stats tab, shared by Yomu (characters read), Miru (time watched) and Kiku (time listened).
public struct StatsView<Cover: View>: View {
    @Environment(\.openURL) private var openURL
    @State private var model: StatsModel
    let kind: ActivitySession.Kind
    let cover: (StatsSummary.Series) -> Cover

    /// This app's Stats, or kechimochi's for all immersion (never added together).
    enum Board: Hashable { case app, all }
    @State private var board = Board.app
    @State private var immersion: ImmersionModel

    public init(kind: ActivitySession.Kind, environment: CommonEnvironment, @ViewBuilder cover: @escaping (StatsSummary.Series) -> Cover) {
        _model = State(initialValue: StatsModel(kind: kind, environment: environment))
        _immersion = State(initialValue: ImmersionModel(environment: environment))
        self.kind = kind
        self.cover = cover
    }

    public var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                if board == .app, let columns = WideColumns.make(geometry), let summary = model.summary, !summary.series.isEmpty {
                    // Wide (the iPhone Duo open, an iPad sideways): the numbers on the left, the
                    // series on the right.
                    HStack(alignment: .top, spacing: 0) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 16) {
                                boardPicker
                                periodPicker
                                chartCard(summary)
                                tiles(summary)
                            }
                            .padding()
                        }
                        .frame(width: columns.left)
                        Color.clear.frame(width: columns.gap)
                        ScrollView {
                            seriesList(summary).padding()
                        }
                        .frame(width: columns.right)
                    }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            boardPicker
                            switch board {
                            case .app: appStats
                            case .all:
                                AllImmersionView(model: immersion, appName: Self.appName(kind))
                                    // Each time it shows (back from Settings ▸ Stats with a new address too).
                                    .task { await immersion.load() }
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("Stats")
            .task { await model.load() }
            .onReceive(NotificationCenter.default.publisher(for: .kechimochiAddressDidChange)) { _ in
                Task { await immersion.load() }
            }
            .refreshable {
                switch board {
                case .app: await model.load()
                case .all: await immersion.load()
                }
            }
        }
    }

    private var boardPicker: some View {
        Picker("Stats", selection: $board) {
            Text(Self.appName(kind)).tag(Board.app)
            Text("All immersion").tag(Board.all)
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("stats.board")
    }

    private var periodPicker: some View {
        Picker("Period", selection: $model.period) {
            Text("Week").tag(StatsSummary.Period.week)
            Text("Month").tag(StatsSummary.Period.month)
            Text("All Time").tag(StatsSummary.Period.allTime)
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("stats.period")
    }

    /// This app's own numbers.
    @ViewBuilder private var appStats: some View {
        periodPicker
        if let summary = model.summary {
            chartCard(summary)
            tiles(summary)
            if !summary.series.isEmpty { seriesList(summary) }
        }
    }

    static func appName(_ kind: ActivitySession.Kind) -> String {
        switch kind {
        case .reading: "Yomu"
        case .watching: "Miru"
        case .listening: "Kiku"
        }
    }

    // MARK: Parts

    private func chartCard(_ summary: StatsSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(kind == .reading ? "Characters read" : kind == .listening ? "Time listened" : "Time watched").foregroundStyle(.secondary)
                Spacer()
                if summary.streak > 0 {
                    Text("\(summary.streak)-day streak").foregroundStyle(.tint)
                        .accessibilityIdentifier("stats.streak")
                }
            }
            .font(.subheadline)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(kind == .reading ? Int(summary.total).formatted() : Self.duration(summary.total))
                    .font(.largeTitle.bold().monospacedDigit())
                if kind == .reading { Text("字").font(.title3).foregroundStyle(.secondary) }
            }
            .accessibilityIdentifier("stats.total")
            Chart(summary.bars) { bar in
                BarMark(x: .value("Day", bar.date, unit: model.period == .allTime ? .month : .day),
                        y: .value(kind == .reading ? "Characters" : "Minutes", kind == .reading ? bar.value : bar.value / 60))
                    .foregroundStyle(.tint.opacity(bar.isCurrent ? 1 : 0.6))
                    .clipShape(.rect(cornerRadius: 6))
            }
            .chartYAxis(.hidden)
            // A floor for the scale, so a few seconds don't fill the chart.
            .chartYScale(domain: 0...max(summary.bars.map { kind == .reading ? $0.value : $0.value / 60 }.max() ?? 0,
                                         kind == .reading ? 500 : 10))
            .chartXAxis {
                switch model.period {
                case .week:
                    AxisMarks(values: .stride(by: .day)) { _ in AxisValueLabel(format: .dateTime.weekday(.narrow), centered: true) }
                case .month:
                    AxisMarks(values: .stride(by: .day, count: 7)) { _ in AxisValueLabel(format: .dateTime.day()) }
                case .allTime:
                    AxisMarks(values: .stride(by: .month)) { _ in AxisValueLabel(format: .dateTime.month(.narrow), centered: true) }
                }
            }
            .frame(height: 180)
        }
        .padding()
        .background(.background.secondary, in: .rect(cornerRadius: 20))
    }

    private func tiles(_ summary: StatsSummary) -> some View {
        HStack(spacing: 10) {
            if kind == .reading {
                tile("Time", Self.duration(summary.seconds))
            } else {
                tile("Episodes", summary.items.formatted())
            }
            tile("Cards mined", summary.cards.formatted())
            tile("Lookups", summary.lookups.formatted())
        }
    }

    private func tile(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
            Text(value).font(.title2.bold().monospacedDigit()).lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.background.secondary, in: .rect(cornerRadius: 16))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("stats.tile")
    }

    private func seriesList(_ summary: StatsSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(kind == .reading ? "By Series" : "By Show").font(.title2.bold())
            VStack(spacing: 0) {
                ForEach(Array(summary.series.enumerated()), id: \.element.id) { index, series in
                    if index > 0 { Divider().padding(.leading, 76) }
                    HStack(spacing: 12) {
                        cover(series)
                            .frame(width: 52, height: kind == .reading ? 72 : 52)
                            .clipShape(.rect(cornerRadius: 6))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(series.title).lineLimit(1)
                            Text(details(series)).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        if series.cards > 0 {
                            Text("\(series.cards) \(series.cards == 1 ? "card" : "cards")").foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 8)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("stats.series")
                }
            }
            .padding(.horizontal)
            .background(.background.secondary, in: .rect(cornerRadius: 16))
        }
    }

    private func details(_ series: StatsSummary.Series) -> String {
        var parts: [String] = []
        if kind == .reading {
            if series.characters > 0 { parts.append("\(series.characters.formatted()) 字") }
            if series.pages > 0 { parts.append("\(series.pages.formatted()) pages") }
        } else if series.items > 0 {
            parts.append("\(series.items) \(series.items == 1 ? "episode" : "episodes")")
        }
        if series.seconds > 0 { parts.append(Self.duration(series.seconds)) }
        return parts.isEmpty ? "Cards only" : parts.joined(separator: " · ")
    }

    /// "2h 40m", "35m" under an hour, "<1m" under a minute.
    static func duration(_ seconds: Double) -> String {
        if seconds > 0 && seconds < 60 { return "<1m" }
        let minutes = Int(seconds / 60)
        return minutes >= 60 ? "\(minutes / 60)h \(String(format: "%02d", minutes % 60))m" : "\(minutes)m"
    }
}

/// Settings ▸ Stats: where the Stats tab's kechimochi row goes.
public struct StatsSettingsSection: View {
    @Environment(CommonEnvironment.self) private var environment
    @State private var url = ""

    public init() {}

    public var body: some View {
        Section {
            // Labeled: in an iOS form a text field shows only its placeholder.
            LabeledContent("kechimochi") {
                TextField("kechimochi URL", text: $url, prompt: Text(verbatim: "https://…"))
                    .multilineTextAlignment(.trailing)
                    .labelsHidden()
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
                    .onSubmit(save)
                    .accessibilityIdentifier("stats.kechimochiURL")
            }
        } header: {
            Text("Stats")
        } footer: {
            Text("The Stats tab links to kechimochi for everything you read, watch and listen to. Nothing is sent there from this app.")
        }
        .onAppear { url = ((try? environment.activity.kechimochiURL()) ?? nil) ?? "" }
        // Saved as it's typed or pasted: switching tabs may neither end editing nor remove this.
        .onChange(of: url) { save() }
        .onDisappear(perform: save)
    }

    private func save() {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let saved = trimmed.isEmpty ? nil : trimmed
        guard saved != ((try? environment.activity.kechimochiURL()) ?? nil) else { return }
        try? environment.activity.saveKechimochiURL(saved)
        NotificationCenter.default.post(name: .kechimochiAddressDidChange, object: nil)
    }
}

extension Notification.Name {
    /// Settings ▸ Stats has a new kechimochi address: All immersion loads again.
    static let kechimochiAddressDidChange = Notification.Name("kechimochiAddressDidChange")
}

#if DEBUG
/// UI tests: a week of made-up reading or watching, so the Stats tab has something to show.
public func seedStats(_ log: ActivityLog, kind: ActivitySession.Kind, now: Date = Date()) {
    let calendar = Calendar.current
    let shows: [(key: String, title: String)] = switch kind {
    case .reading: [("1", "そら ソラ 空 ガーデン"), ("2", "鉄の時計")]
    case .watching: [("s1", "Star Captain"), ("s2", "Midnight Bridge")]
    case .listening: [("p1", "ことばの散歩ラジオ"), ("p2", "まいにち雑談ラジオ")]
    }
    for (offset, amount) in [(6, 900), (5, 1600), (3, 2100), (2, 1200), (1, 700), (0, 1400)] {
        guard let day = calendar.date(byAdding: .day, value: -offset, to: calendar.startOfDay(for: now))?.addingTimeInterval(19 * 3600),
              day < now else { continue }
        let show = shows[offset % 2]
        let subject = ActivitySubject(kind: kind, seriesKey: show.key, seriesTitle: show.title, itemKey: "\(show.key)-\(offset)")
        try? log.record(subject, at: day, characters: kind == .reading ? amount : 0)
        try? log.record(subject, at: day.addingTimeInterval(240), characters: kind == .reading ? amount / 2 : 0,
                        pages: kind == .reading && offset % 2 == 1 ? 24 : 0, seconds: kind.isTimed ? Double(amount) : 0)
        for minute in 0..<(amount / 300) { try? log.recordLookup(at: day.addingTimeInterval(Double(minute * 60))) }
    }
}
#endif

// MARK: Today

/// Today's numbers for the home screens' Today row, from this device at once (`load`): the
/// day's reading or watching, this app's lookups, and cards (every app's: the mining deck as
/// last fetched, plus this app's unsent cards). `refreshed` fetches the deck first.
public struct TodaySummary: Equatable, Sendable {
    public var characters: Int
    public var seconds: Double
    public var lookups: Int
    public var cards: Int
    public var streak: Int

    @MainActor
    /// The same once the mining deck is asked for again, so every app counts the cards mined
    /// since (in any app) alike.
    public static func refreshed(kind: ActivitySession.Kind, environment: CommonEnvironment) async -> TodaySummary {
        await StatsModel.refreshDeck(environment)
        return load(kind: kind, environment: environment)
    }

    public static func load(kind: ActivitySession.Kind, environment: CommonEnvironment, now: Date = Date()) -> TodaySummary {
        let activity = environment.activity
        let start = Calendar.current.startOfDay(for: now)
        let sessions = (try? activity.sessions(kind: kind)) ?? []
        let today = sessions.filter { $0.start >= start }
        // The deck as Stats last saw it (note ids are creation times in ms), plus this app's cards
        // not in that copy yet: unsent, or sent after it was taken.
        let cached = (try? activity.cachedAnkiNoteIds()) ?? []
        let ankiToday = cached.filter { $0 >= Int64(start.timeIntervalSince1970 * 1000) }.count
        let cachedUntil = Date(timeIntervalSince1970: Double(cached.max() ?? 0) / 1000)
        let own = ((try? environment.outbox.jobs(states: [.pending, .inFlight, .failed, .sent])) ?? [])
            .filter { $0.kind == .ankiNote && $0.createdAt >= start }
        let unsentToday = own.filter { $0.state != .sent || $0.updatedAt > cachedUntil }.count
        let week = StatsSummary.make(kind: kind, period: .week, sessions: sessions, lookups: [], cards: [], ownCards: [], now: now)
        return TodaySummary(characters: today.reduce(0) { $0 + $1.characters }, seconds: today.reduce(0) { $0 + $1.duration },
                            lookups: ((try? activity.lookupDates(since: start)) ?? []).count, cards: ankiToday + unsentToday,
                            streak: week.streak)
    }
}

/// "TODAY · 1,240 字 · 18 min · 6 cards", opening the Stats tab.
public struct TodayRow: View {
    let kind: ActivitySession.Kind
    let today: TodaySummary
    let open: () -> Void

    public init(kind: ActivitySession.Kind, today: TodaySummary, open: @escaping () -> Void) {
        self.kind = kind
        self.today = today
        self.open = open
    }

    public var body: some View {
        Button(action: open) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Today").font(.caption.weight(.semibold)).textCase(.uppercase).foregroundStyle(.secondary)
                    summary.lineLimit(1).minimumScaleFactor(0.7)
                }
                Spacer(minLength: 8)
                if kind == .reading, today.streak > 0 {
                    Text("\(today.streak)-day streak").font(.subheadline).foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .padding()
            .background(.background.secondary, in: .rect(cornerRadius: 18))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("home.today")
    }

    private var summary: Text {
        // A few seconds read as "<1", not 0.
        let minutes = today.seconds > 0 && today.seconds < 60 ? "<1" : "\(Int(today.seconds / 60))"
        let cards = Text("\(today.cards)").bold() + Text(today.cards == 1 ? " card" : " cards")
        let lookups = Text("\(today.lookups)").bold() + Text(today.lookups == 1 ? " lookup · " : " lookups · ")
        if kind == .reading {
            return Text(today.characters.formatted()).bold().foregroundStyle(.tint) + Text(" 字 · ")
                + Text(minutes).bold() + Text(" min · ") + lookups + cards
        }
        return Text(minutes).bold().foregroundStyle(.tint) + Text(" min · ") + lookups + cards
    }
}

// MARK: Cover tint

/// The average colour of a cover or poster, for tinting a series page's header.
public enum CoverTint {
    public static func color(of image: CGImage) -> Color? {
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return Color(.sRGB, red: Double(pixel[0]) / 255, green: Double(pixel[1]) / 255, blue: Double(pixel[2]) / 255)
    }
}

/// A series page's header background: the cover's colour fading into the page.
public struct TintedHeaderBackground: View {
    let color: Color?

    public init(color: Color?) {
        self.color = color
    }

    public var body: some View {
        LinearGradient(colors: [(color ?? .clear).opacity(0.75), (color ?? .clear).opacity(0)], startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea(edges: .top)
            .animation(.easeInOut(duration: 0.3), value: color)
    }
}

/// Text cut to `lines` lines with a "more" button that shows the rest.
public struct ExpandableText: View {
    let text: String
    var lines = 2
    @State private var expanded = false

    public init(_ text: String, lines: Int = 2) {
        self.text = text
        self.lines = lines
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(text).lineLimit(expanded ? nil : lines).foregroundStyle(.secondary)
            Button(expanded ? "less" : "more") { withAnimation { expanded.toggle() } }
                .font(.subheadline)
                .accessibilityIdentifier("series.more")
        }
    }
}

/// Small capsules in a row (genres, seasons).
public struct ChipRow<Item: Hashable, Label: View>: View {
    let items: [Item]
    let label: (Item) -> Label

    public init(_ items: [Item], @ViewBuilder label: @escaping (Item) -> Label) {
        self.items = items
        self.label = label
    }

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(items, id: \.self) { label($0) }
            }
        }
        .shelfScrollClip()
    }
}
