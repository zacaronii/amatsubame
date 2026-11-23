import Foundation
import GRDB

/// A daily goal for an activity (Yomu's reading): so many characters, pages or minutes a day.
/// Kept as a history, each change from the day it was made, so every day counts against the goal
/// it had then; a target of 0 is "off". On this device (Stats settings aren't synced).
public struct DailyGoal: Codable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "dailyGoal"

    public var id: Int64?
    public var kind: ActivitySession.Kind
    public var measure: StatsSummary.Measure
    /// Characters, pages, or minutes for `time`; 0 is no goal.
    public var target: Int
    /// The day it holds from (the start of that day).
    public var since: Date

    public init(kind: ActivitySession.Kind, measure: StatsSummary.Measure, target: Int, since: Date) {
        self.kind = kind
        self.measure = measure
        self.target = target
        self.since = since
    }

    public var isOn: Bool { target > 0 }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

extension StatsSummary.Measure: Codable, DatabaseValueConvertible {}
extension ActivitySession.Kind: DatabaseValueConvertible {}

/// The goals' history and what it says about days.
public struct DailyGoals: Equatable, Sendable {
    /// Oldest first.
    public let history: [DailyGoal]
    public let calendar: Calendar

    public init(history: [DailyGoal], calendar: Calendar = .current) {
        self.history = history.sorted { $0.since < $1.since }
        self.calendar = calendar
    }

    /// The goal a day had (nil: none, or turned off).
    public func goal(on day: Date) -> DailyGoal? {
        let start = calendar.startOfDay(for: day)
        let goal = history.last { $0.since <= start }
        return goal?.isOn == true ? goal : nil
    }

    /// How far the day got, in the goal's measure (minutes for time).
    public func progress(on day: Date, sessions: [ActivitySession], measure: StatsSummary.Measure) -> Int {
        guard let interval = calendar.dateInterval(of: .day, for: day) else { return 0 }
        let today = sessions.filter { interval.contains($0.start) }
        switch measure {
        case .characters: return today.reduce(0) { $0 + $1.characters }
        case .pages: return today.reduce(0) { $0 + $1.pages }
        case .time: return Int(today.reduce(0) { $0 + $1.duration } / 60)
        }
    }

    /// Whether a day met the goal it had.
    public func met(on day: Date, sessions: [ActivitySession]) -> Bool {
        guard let goal = goal(on: day) else { return false }
        return progress(on: day, sessions: sessions, measure: goal.measure) >= goal.target
    }

    /// Days in a row meeting their goals, up to today (today counts once met; until then the
    /// streak runs to yesterday).
    public func streak(sessions: [ActivitySession], now: Date = .now) -> Int {
        var day = calendar.startOfDay(for: now)
        if !met(on: day, sessions: sessions) { day = calendar.date(byAdding: .day, value: -1, to: day) ?? day }
        var count = 0
        while met(on: day, sessions: sessions), count < 3660 {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        return count
    }
}

public struct DailyGoalStore: Sendable {
    let database: AppDatabase
    /// Thread-safe, though not marked Sendable: only the once-a-day note's date is kept in it.
    nonisolated(unsafe) let defaults: UserDefaults

    public init(database: AppDatabase, defaults: UserDefaults = .standard) {
        self.database = database
        self.defaults = defaults
    }

    public func goals(kind: ActivitySession.Kind, calendar: Calendar = .current) throws -> DailyGoals {
        try database.reader.read { db in
            DailyGoals(history: try DailyGoal.filter(Column("kind") == kind).fetchAll(db), calendar: calendar)
        }
    }

    /// Sets today's goal (and on): a change today replaces today's row, so the history keeps
    /// one goal a day. A target of 0 turns it off.
    public func set(kind: ActivitySession.Kind, measure: StatsSummary.Measure, target: Int, now: Date = .now, calendar: Calendar = .current) throws {
        let today = calendar.startOfDay(for: now)
        try database.writer.write { db in
            try DailyGoal.filter(Column("kind") == kind && Column("since") == today).deleteAll(db)
            var goal = DailyGoal(kind: kind, measure: measure, target: max(target, 0), since: today)
            try goal.insert(db)
        }
    }

    /// Whether today's goal has just been reached on this device and not yet said: true once a
    /// day (the reader shows "Daily goal reached").
    public func reachedTodayFirstTime(kind: ActivitySession.Kind, log: ActivityLog, now: Date = .now, calendar: Calendar = .current) -> Bool {
        let key = "dailyGoal.reached.\(kind.rawValue)"
        let today = calendar.startOfDay(for: now)
        if let said = defaults.object(forKey: key) as? Date, said >= today { return false }
        guard let goals = try? goals(kind: kind, calendar: calendar), let goal = goals.goal(on: now),
              let sessions = try? log.sessions(kind: kind, since: today, localOnly: true),
              goals.progress(on: now, sessions: sessions, measure: goal.measure) >= goal.target else { return false }
        defaults.set(today, forKey: key)
        return true
    }
}

/// Daily goals with Sync with iCloud: one record per kind and day ("reading/2026-11-23"), so
/// two devices' goals merge by day and each day keeps the goal it had. The days are calendar
/// days where the goal was set. The once-a-day "reached" note stays per device.
public struct DailyGoalCollection: SyncedCollection {
    public let name = "dailyGoals"
    let calendar: Calendar

    public init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    struct Value: Codable {
        var kind: ActivitySession.Kind
        var measure: StatsSummary.Measure
        var target: Int
        var day: String
    }

    func day(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    func date(_ day: String) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    public func records(_ db: Database) throws -> [String: Data] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        var result: [String: Data] = [:]
        for goal in try DailyGoal.order(Column("since"), Column("id")).fetchAll(db) {
            let value = Value(kind: goal.kind, measure: goal.measure, target: goal.target, day: day(goal.since))
            result["\(goal.kind.rawValue)/\(value.day)"] = try encoder.encode(value)
        }
        return result
    }

    public func apply(id: String, value: Data?, _ db: Database) throws {
        let parts = id.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2, let kind = ActivitySession.Kind(rawValue: parts[0]), let start = date(parts[1]),
              let end = calendar.date(byAdding: .day, value: 1, to: start) else { return }
        try DailyGoal.filter(Column("kind") == kind && Column("since") >= start && Column("since") < end).deleteAll(db)
        guard let value, let decoded = try? JSONDecoder().decode(Value.self, from: value), decoded.kind == kind else { return }
        var goal = DailyGoal(kind: kind, measure: decoded.measure, target: decoded.target, since: start)
        try goal.insert(db)
    }
}
