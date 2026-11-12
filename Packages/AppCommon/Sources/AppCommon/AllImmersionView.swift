import Core
import KechimochiKit
import Observation
import SwiftUI

/// Stats ▸ All immersion: kechimochi's own totals (read only), shown next to the app's Stats and
/// never added to them, so a session logged in both isn't counted twice. The last answers are
/// kept, so it shows offline with their age.
@MainActor @Observable
public final class ImmersionModel {
    public private(set) var snapshot: KechimochiSnapshot?
    public private(set) var fetchedAt: Date?
    public private(set) var problem: String?
    public private(set) var isLoading = false
    /// The year the heatmap shows, and the years kechimochi has logs in.
    public var year: Int
    public private(set) var heatmaps: [Int: KechimochiHeatmap] = [:]
    public private(set) var webURL: URL?

    @ObservationIgnored private let environment: CommonEnvironment
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private let now: () -> Date

    public init(environment: CommonEnvironment, calendar: Calendar = .current, now: @escaping () -> Date = Date.init) {
        self.environment = environment
        self.calendar = calendar
        self.now = now
        year = calendar.component(.year, from: now())
    }

    public var currentYear: Int { calendar.component(.year, from: now()) }

    /// From the first log's year to now.
    public var years: [Int] {
        let first = snapshot?.summary.firstActivityDate.flatMap { Int($0.prefix(4)) } ?? currentYear
        return Array(min(first, currentYear)...currentYear).reversed()
    }

    public var heatmap: KechimochiHeatmap? { year == currentYear ? snapshot?.heatmap : heatmaps[year] }

    /// The saved answers at once, then kechimochi's.
    public func load() async {
        webURL = ((try? environment.activity.kechimochiURL()) ?? nil).flatMap { URL(string: $0) }
        if snapshot == nil, let cached = try? environment.activity.kechimochiCache("snapshot"),
           let saved = try? JSONDecoder().decode(KechimochiSnapshot.self, from: cached.data) {
            snapshot = saved
            fetchedAt = cached.fetchedAt
        }
        guard let client else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let fresh = try await client.snapshot(today: Self.dayString(now(), calendar: calendar), year: currentYear)
            snapshot = fresh
            fetchedAt = now()
            problem = nil
            if let data = try? JSONEncoder().encode(fresh) { try? environment.activity.saveKechimochiCache("snapshot", data: data, at: now()) }
        } catch {
            guard !error.isCancellation else { return }
            problem = "Can't reach kechimochi."
        }
        if year != currentYear { await loadYear() }
    }

    /// Another year's heatmap (the year menu): saved, then fetched.
    public func loadYear() async {
        let year = year
        guard year != currentYear else { return }
        let key = "heatmap-\(year)"
        if heatmaps[year] == nil, let cached = try? environment.activity.kechimochiCache(key),
           let saved = try? JSONDecoder().decode(KechimochiHeatmap.self, from: cached.data) {
            heatmaps[year] = saved
        }
        guard let client, let fresh = try? await client.heatmap(year: year) else { return }
        heatmaps[year] = fresh
        if let data = try? JSONEncoder().encode(fresh) { try? environment.activity.saveKechimochiCache(key, data: data, at: now()) }
    }

    /// The API is on the same host as the page set in Settings ▸ Stats.
    private var client: KechimochiClient? {
        guard let webURL, var components = URLComponents(url: webURL, resolvingAgainstBaseURL: false) else { return nil }
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url.map { KechimochiClient(baseURL: $0, http: environment.http) }
    }

    static func dayString(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// "41h 37m", "38 m".
    public static func duration(_ minutes: Int, spaced: Bool = false) -> String {
        let hours = minutes / 60, rest = minutes % 60
        guard hours > 0 else { return "\(minutes) m" }
        return spaced ? "\(hours) h \(String(format: "%02d", rest)) m" : "\(hours)h \(rest)m"
    }

    /// "Jun 14" (a day), "Jun 2026" (a month), "2026" (a year).
    public static func since(_ date: String) -> String {
        let parts = date.split(separator: "-").compactMap { Int($0) }
        var components = DateComponents(year: parts.first, month: parts.count > 1 ? parts[1] : 1, day: parts.count > 2 ? parts[2] : 1)
        components.calendar = Calendar(identifier: .gregorian)
        guard let day = components.date else { return date }
        switch parts.count {
        case 3: return day.formatted(.dateTime.month(.abbreviated).day())
        case 2: return day.formatted(.dateTime.month(.abbreviated).year())
        default: return String(parts.first ?? 0)
        }
    }
}

/// The All immersion board: the heatmap with the streak, three tiles, time
/// by activity type in each app's color, and a link to kechimochi.
struct AllImmersionView: View {
    @Environment(\.openURL) private var openURL
    let model: ImmersionModel
    /// "Kiku": the footer says these totals aren't added to this app's.
    let appName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if model.webURL == nil {
                ContentUnavailableView {
                    Label("Connect kechimochi", systemImage: "chart.bar.xaxis")
                } description: {
                    Text("Add kechimochi's address in Settings ▸ Stats to see all your immersion here.")
                }
            } else if let snapshot = model.snapshot {
                HeatmapCard(model: model, summary: snapshot.summary)
                tiles(snapshot.summary)
                byMedia(snapshot.summary)
                openRow
                footer
            } else if model.isLoading {
                ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
            } else {
                ContentUnavailableView {
                    Label("Can't Reach kechimochi", systemImage: "wifi.exclamationmark")
                } description: {
                    Text("All immersion shows here once kechimochi has been reached.")
                }
                openRow
            }
        }
        .accessibilityIdentifier("stats.allImmersion")
    }

    private func tiles(_ summary: KechimochiSummary) -> some View {
        HStack(spacing: 0) {
            tile("Total", ImmersionModel.duration(summary.totalMinutes),
                 summary.firstActivityDate.map { "since \(ImmersionModel.since($0))" } ?? "")
            Divider().padding(.vertical, 6)
            tile("Longest streak", summary.maxStreak == 1 ? "1 day" : "\(summary.maxStreak) days", "current \(summary.currentStreak)")
            Divider().padding(.vertical, 6)
            tile("Daily average", ImmersionModel.duration(summary.dailyAverageMinutes),
                 summary.loggedDays == 1 ? "1 day logged" : "\(summary.loggedDays) days logged")
        }
        .padding(.vertical, 14)
        .background(.background.secondary, in: .rect(cornerRadius: 22))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("immersion.tiles")
    }

    private func tile(_ title: String, _ value: String, _ detail: String) -> some View {
        VStack(spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.bold()).monospacedDigit().minimumScaleFactor(0.7).lineLimit(1)
            Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private func byMedia(_ summary: KechimochiSummary) -> some View {
        let most = max(summary.activityTotals.map(\.totalMinutes).max() ?? 1, 1)
        return VStack(alignment: .leading, spacing: 14) {
            Text("By media").font(.subheadline).foregroundStyle(.secondary)
            ForEach(summary.activityTotals, id: \.key) { total in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(total.label)
                        Spacer()
                        Text(ImmersionModel.duration(total.totalMinutes, spaced: true)).foregroundStyle(.secondary).monospacedDigit()
                    }
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.quaternary)
                            Capsule().fill(Self.color(for: total.label))
                                .frame(width: max(8, geometry.size.width * CGFloat(total.totalMinutes) / CGFloat(most)))
                        }
                    }
                    .frame(height: 8)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding()
        .background(.background.secondary, in: .rect(cornerRadius: 22))
    }

    /// Each kind of immersion in its app's color: Listening Kiku, Watching Miru, Reading Yomu.
    static func color(for activity: String) -> Color {
        switch activity.lowercased() {
        case "listening": Color(red: 0xF7 / 255, green: 0x9A / 255, blue: 0x3E / 255)
        case "watching": Color(red: 0xB9 / 255, green: 0x8A / 255, blue: 0xF5 / 255)
        case "reading": Color(red: 0x3F / 255, green: 0xC9 / 255, blue: 0x8F / 255)
        default: Color(white: 0.55)
        }
    }

    @ViewBuilder private var openRow: some View {
        if let url = model.webURL {
            Button {
                openURL(url)
            } label: {
                HStack {
                    Text("Open kechimochi")
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                }
                .padding()
                .background(.background.secondary, in: .rect(cornerRadius: 16))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("stats.kechimochi")
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 2) {
            Group {
                if let fetchedAt = model.fetchedAt {
                    Text("From kechimochi · updated \(fetchedAt, format: .relative(presentation: .named))")
                } else {
                    Text("From kechimochi")
                }
            }
            if model.problem != nil { Text("Can't reach kechimochi: showing the last update.") }
            Text("These are kechimochi's own totals; they aren't added to \(appName)'s.")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("immersion.footer")
    }
}

/// "Activity · 22-day streak", the year menu, the day grid (newest week at the right, swipe
/// for earlier ones), and a caption with the tapped day's (or today's) minutes.
private struct HeatmapCard: View {
    let model: ImmersionModel
    let summary: KechimochiSummary
    @State private var selected: ImmersionHeatmap.Day?
    /// Some weeks are out of sight (a wide screen, like the open iPhone Duo, fits the year).
    @State private var overflows = false

    static let cell: CGFloat = 14, gap: CGFloat = 4

    var body: some View {
        let grid = ImmersionHeatmap(year: model.year, days: model.heatmap?.days ?? [], today: Date())
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Activity").foregroundStyle(.secondary)
                    + Text(summary.currentStreak > 0 ? " · \(summary.currentStreak)-day streak" : "").foregroundStyle(.tint)
                Spacer()
                if model.years.count < 2 {
                    // Only this year's logs: nothing to choose.
                    Text(String(model.year)).foregroundStyle(.tint)
                        .accessibilityIdentifier("immersion.year")
                } else {
                    Menu {
                        ForEach(model.years, id: \.self) { year in
                            Button(String(year)) {
                                model.year = year
                                selected = nil
                                Task { await model.loadYear() }
                            }
                        }
                    } label: {
                        HStack(spacing: 2) {
                            Text(String(model.year))
                            Image(systemName: "chevron.down").font(.caption2.weight(.bold))
                        }
                        .foregroundStyle(.tint)
                    }
                    .accessibilityIdentifier("immersion.year")
                }
            }
            .font(.subheadline)
            HStack(alignment: .top, spacing: 6) {
                VStack(spacing: Self.gap) {
                    Text(" ").font(.caption2)
                    ForEach(0..<7, id: \.self) { row in
                        Text(["", "M", "", "W", "", "F", ""][row]).font(.caption2).foregroundStyle(.secondary)
                            .frame(height: Self.cell)
                    }
                }
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        VStack(alignment: .leading, spacing: Self.gap) {
                            ZStack(alignment: .topLeading) {
                                Color.clear.frame(height: 14)
                                ForEach(grid.monthLabels, id: \.column) { label in
                                    Text(label.name).font(.caption2).foregroundStyle(.secondary).fixedSize()
                                        .offset(x: CGFloat(label.column) * (Self.cell + Self.gap))
                                }
                            }
                            HStack(spacing: Self.gap) {
                                ForEach(Array(grid.weeks.enumerated()), id: \.offset) { index, week in
                                    VStack(spacing: Self.gap) {
                                        ForEach(week) { day in square(day) }
                                    }
                                    .id(index)
                                }
                            }
                        }
                    }
                    // Room for the last month's name after the newest week.
                    .contentMargins(.trailing, 14, for: .scrollContent)
                    .scrollIndicators(.hidden)
                    .defaultScrollAnchor(.trailing)
                    .onScrollGeometryChange(for: Bool.self) { $0.contentSize.width > $0.containerSize.width + 1 } action: { _, value in
                        overflows = value
                    }
                    .onChange(of: model.year) { _, _ in proxy.scrollTo(grid.weeks.count - 1, anchor: .trailing) }
                }
            }
            HStack {
                Text(caption(grid)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                HStack(spacing: 3) {
                    Text("Less").font(.caption2).foregroundStyle(.secondary)
                    ForEach(0..<5, id: \.self) { level in shade(level).frame(width: 10, height: 10) }
                    Text("More").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .background(.background.secondary, in: .rect(cornerRadius: 22))
        .accessibilityIdentifier("immersion.heatmap")
    }

    @ViewBuilder private func square(_ day: ImmersionHeatmap.Day) -> some View {
        if day.isPlaceholder {
            Color.clear.frame(width: Self.cell, height: Self.cell)
        } else {
            shade(day.level)
                .frame(width: Self.cell, height: Self.cell)
                .overlay {
                    if day.isToday || selected?.date == day.date {
                        RoundedRectangle(cornerRadius: 3).strokeBorder(.primary, lineWidth: 1.5)
                    }
                }
                .contentShape(.rect)
                .onTapGesture { selected = selected?.date == day.date ? nil : day }
                .accessibilityLabel("\(day.date): \(ImmersionModel.duration(day.minutes))")
        }
    }

    /// Empty (a neutral grey, clearly apart from the lightest shade in light and dark), then four
    /// shades of the app's accent.
    private func shade(_ level: Int) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(level == 0 ? AnyShapeStyle(Color.primary.opacity(0.08)) : AnyShapeStyle(.tint.opacity([0, 0.4, 0.6, 0.8, 1][level])))
    }

    private func caption(_ grid: ImmersionHeatmap) -> String {
        if let selected {
            let parts = selected.date.split(separator: "-").compactMap { Int($0) }
            var components = DateComponents(year: parts.first, month: parts.dropFirst().first, day: parts.last)
            components.calendar = Calendar(identifier: .gregorian)
            let name = components.date?.formatted(.dateTime.month(.abbreviated).day()) ?? selected.date
            return "\(name): \(ImmersionModel.duration(selected.minutes))"
        }
        let today = grid.weeks.joined().first(where: \.isToday)
        let swipe = overflows ? " · swipe for more" : ""
        return today.map { "Today: \(ImmersionModel.duration($0.minutes))\(swipe)" } ?? "Tap a day for its minutes"
    }
}
