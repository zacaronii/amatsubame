import Core
import Foundation
import Testing

/// Daily goals on made-up sessions (a fixed calendar, so days are the same everywhere).
@Suite struct DailyGoalTests {
    var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    let monday = Date(timeIntervalSince1970: 1_795_651_200) // a Monday, 00:00 UTC

    func day(_ n: Int, hour: Int = 10) -> Date { monday.addingTimeInterval(Double(n) * 86_400 + Double(hour) * 3600) }

    func reading(_ day: Date, characters: Int = 0, pages: Int = 0, minutes: Double = 0) -> ActivitySession {
        ActivitySession(kind: .reading, seriesKey: "s", seriesTitle: "本", itemKey: "1", start: day, end: day.addingTimeInterval(minutes * 60),
                        characters: characters, pages: pages)
    }

    @Test func progressInEachMeasure() {
        let goals = DailyGoals(history: [DailyGoal(kind: .reading, measure: .characters, target: 1000, since: monday)], calendar: calendar)
        let sessions = [reading(day(0), characters: 600, pages: 4, minutes: 20), reading(day(0, hour: 21), characters: 500, pages: 3, minutes: 15),
                        reading(day(1), characters: 9999)]
        #expect(goals.progress(on: day(0), sessions: sessions, measure: .characters) == 1100)
        #expect(goals.progress(on: day(0), sessions: sessions, measure: .pages) == 7)
        #expect(goals.progress(on: day(0), sessions: sessions, measure: .time) == 35)
        #expect(goals.met(on: day(0), sessions: sessions))
    }

    /// Each day counts against the goal it had: a goal raised on Wednesday doesn't unmeet Monday.
    @Test func daysKeepTheGoalTheyHad() {
        let goals = DailyGoals(history: [
            DailyGoal(kind: .reading, measure: .characters, target: 500, since: monday),
            DailyGoal(kind: .reading, measure: .characters, target: 2000, since: day(2, hour: 0)),
            DailyGoal(kind: .reading, measure: .pages, target: 0, since: day(4, hour: 0)),
        ], calendar: calendar)
        let sessions = (0..<5).map { reading(day($0), characters: 800) }
        #expect(goals.met(on: day(0), sessions: sessions) && goals.met(on: day(1), sessions: sessions))
        #expect(!goals.met(on: day(2), sessions: sessions), "800 of the new 2000")
        #expect(goals.goal(on: day(4)) == nil, "turned off on Friday")
        #expect(goals.goal(on: day(-1)) == nil, "before any goal")
    }

    @Test func theStreakCountsDaysMetUpToToday() {
        let goals = DailyGoals(history: [DailyGoal(kind: .reading, measure: .pages, target: 10, since: monday)], calendar: calendar)
        var sessions = [reading(day(0), pages: 12), reading(day(1), pages: 10), reading(day(2), pages: 15)]
        #expect(goals.streak(sessions: sessions, now: day(3, hour: 9)) == 3, "today not met yet: up to yesterday")
        sessions.append(reading(day(3, hour: 8), pages: 10))
        #expect(goals.streak(sessions: sessions, now: day(3, hour: 9)) == 4)
        #expect(goals.streak(sessions: [reading(day(0), pages: 12), reading(day(2), pages: 12)], now: day(2, hour: 12)) == 1, "a gap ends it")
    }

    @Test func settingTodayTwiceKeepsOneRowAndTheNoteComesOnce() throws {
        let database = try AppDatabase.inMemory()
        let defaults = try #require(UserDefaults(suiteName: "DailyGoalTests-\(UUID().uuidString)"))
        let store = DailyGoalStore(database: database, defaults: defaults)
        let log = ActivityLog(database: database)
        let now = Date()
        try store.set(kind: .reading, measure: .characters, target: 300, now: now, calendar: calendar)
        try store.set(kind: .reading, measure: .characters, target: 100, now: now, calendar: calendar)
        let goals = try store.goals(kind: .reading, calendar: calendar)
        #expect(goals.history.count == 1 && goals.goal(on: now)?.target == 100)
        #expect(!store.reachedTodayFirstTime(kind: .reading, log: log, now: now, calendar: calendar), "nothing read yet")
        try log.record(ActivitySubject(kind: .reading, seriesKey: "s", seriesTitle: "本", itemKey: "1"), at: now, characters: 150)
        #expect(store.reachedTodayFirstTime(kind: .reading, log: log, now: now, calendar: calendar))
        #expect(!store.reachedTodayFirstTime(kind: .reading, log: log, now: now, calendar: calendar), "once a day")
    }
}
