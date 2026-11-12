import Foundation
import KechimochiKit

/// The All immersion heatmap's grid: one column per week (Sunday at the top), from the week of
/// January 1 to the week of December 31, or of today in the current year.
public struct ImmersionHeatmap: Equatable, Sendable {
    public struct Day: Equatable, Sendable, Identifiable {
        /// "2026-11-07".
        public var date: String
        public var minutes: Int
        /// 0 (nothing) to 4 (the year's busiest days).
        public var level: Int
        /// Outside the year, or after today: drawn as a gap.
        public var isPlaceholder: Bool
        public var isToday: Bool
        public var id: String { date }
    }

    /// Weeks, each seven days from Sunday.
    public var weeks: [[Day]]
    /// Month names over the columns where a month starts: (column, "Jul").
    public var monthLabels: [(column: Int, name: String)]

    public static func == (a: ImmersionHeatmap, b: ImmersionHeatmap) -> Bool {
        a.weeks == b.weeks && a.monthLabels.map(\.column) == b.monthLabels.map(\.column)
            && a.monthLabels.map(\.name) == b.monthLabels.map(\.name)
    }

    /// Shades, as GitHub does: the year's days with activity split into quarters, so a few big
    /// days don't leave everything else in the lightest shade. `thresholds` are the upper bounds
    /// of the first three quarters (`thresholds(_:)`).
    /// The year's busiest day is always the brightest.
    public static func level(_ minutes: Int, thresholds: [Int], busiest: Int = .max) -> Int {
        guard minutes > 0 else { return 0 }
        if minutes >= busiest { return 4 }
        return 1 + thresholds.prefix(3).count { minutes > $0 }
    }

    /// The 25th, 50th and 75th percentiles of the days with activity.
    public static func thresholds(_ minutes: [Int]) -> [Int] {
        let sorted = minutes.filter { $0 > 0 }.sorted()
        guard !sorted.isEmpty else { return [] }
        return [0.25, 0.5, 0.75].map { sorted[Swift.min(sorted.count - 1, Int(Double(sorted.count) * $0))] }
    }

    public init(year: Int, days: [KechimochiDay], today: Date, calendar: Calendar = .current) {
        var calendar = calendar
        calendar.firstWeekday = 1
        let minutes = Dictionary(days.map { ($0.date, $0.totalMinutes) }, uniquingKeysWith: +)
        let thresholds = Self.thresholds(Array(minutes.values))
        let busiest = minutes.values.max() ?? .max
        let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1))!
        let yearEnd = calendar.date(from: DateComponents(year: year, month: 12, day: 31))!
        let todayStart = calendar.startOfDay(for: today)
        let end = min(yearEnd, todayStart)
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let monthName = DateFormatter()
        monthName.calendar = calendar
        monthName.dateFormat = "MMM"

        // From the Sunday on or before January 1.
        var day = calendar.date(byAdding: .day, value: -(calendar.component(.weekday, from: start) - 1), to: start)!
        var weeks: [[Day]] = []
        var labels: [(Int, String)] = []
        var lastMonth = -1
        while day <= end {
            var week: [Day] = []
            for _ in 0..<7 {
                let key = formatter.string(from: day)
                let inside = day >= start && day <= end
                let value = inside ? minutes[key] ?? 0 : 0
                week.append(Day(date: key, minutes: value, level: Self.level(value, thresholds: thresholds, busiest: busiest),
                                isPlaceholder: !inside, isToday: day == todayStart))
                if inside, calendar.component(.day, from: day) == 1 || day == start {
                    let month = calendar.component(.month, from: day)
                    if month != lastMonth {
                        lastMonth = month
                        // Over the column where the month's first day is.
                        labels.append((weeks.count, monthName.string(from: day)))
                    }
                }
                day = calendar.date(byAdding: .day, value: 1, to: day)!
            }
            weeks.append(week)
        }
        self.weeks = weeks
        // Two labels in neighbouring columns would overlap: keep the later one.
        var spaced: [(column: Int, name: String)] = []
        for label in labels {
            if let last = spaced.last, label.0 - last.column < 2 { spaced.removeLast() }
            spaced.append((label.0, label.1))
        }
        monthLabels = spaced
    }
}
