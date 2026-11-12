import Foundation

/// The dashboard's numbers (kechimochi 0.3.3 `DashboardSummary`), all time.
public struct KechimochiSummary: Codable, Equatable, Sendable {
    public struct ActivityTotal: Codable, Equatable, Sendable {
        /// "activity:Listening".
        public var key: String
        /// "Listening", "Watching", "Reading", "Playing", or a user-defined type.
        public var label: String
        public var totalMinutes: Int

        enum CodingKeys: String, CodingKey {
            case key, label
            case totalMinutes = "total_minutes"
        }
    }

    public var totalLogs: Int
    public var loggedDays: Int
    /// "2026-06-14" (logs can be dated by month or year too: "2026-06", "2026").
    public var firstActivityDate: String?
    public var lastActivityDate: String?
    public var maxStreak: Int
    public var currentStreak: Int
    public var totalMinutes: Int
    public var activityTotals: [ActivityTotal]

    /// Minutes per logged day.
    public var dailyAverageMinutes: Int {
        loggedDays > 0 ? Int((Double(totalMinutes) / Double(loggedDays)).rounded()) : 0
    }

    enum CodingKeys: String, CodingKey {
        case totalLogs = "total_logs", loggedDays = "logged_days"
        case firstActivityDate = "first_activity_date", lastActivityDate = "last_activity_date"
        case maxStreak = "max_streak", currentStreak = "current_streak"
        case totalMinutes = "total_minutes", activityTotals = "activity_totals"
    }
}

/// One day of the heatmap (only days with activity are listed).
public struct KechimochiDay: Codable, Equatable, Sendable {
    /// "2026-11-07".
    public var date: String
    public var totalMinutes: Int

    public init(date: String, totalMinutes: Int) {
        self.date = date
        self.totalMinutes = totalMinutes
    }

    enum CodingKeys: String, CodingKey {
        case date
        case totalMinutes = "total_minutes"
    }
}

/// A year's heatmap (`DashboardHeatmapYearResponse`).
public struct KechimochiHeatmap: Codable, Equatable, Sendable {
    public var year: Int
    public var days: [KechimochiDay]
}

/// What Stats ▸ All immersion shows: the dashboard snapshot's summary and the current year's
/// heatmap (the snapshot's settings, recent logs and weekday stats aren't kept).
public struct KechimochiSnapshot: Codable, Equatable, Sendable {
    public var summary: KechimochiSummary
    public var heatmap: KechimochiHeatmap
}
