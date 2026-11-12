@testable import AppCommon
import Foundation
import KechimochiKit
import Testing

@MainActor @Suite struct ImmersionTests {
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        return calendar
    }

    func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }

    /// Quarters of the days with activity: one huge day doesn't wash out the rest.
    @Test func shadesFollowTheYearsSpread() {
        let year = [5, 10, 20, 30, 40, 50, 60, 600]
        let thresholds = ImmersionHeatmap.thresholds(year)
        #expect(thresholds == [20, 40, 60])
        #expect(ImmersionHeatmap.level(0, thresholds: thresholds) == 0)
        #expect(ImmersionHeatmap.level(5, thresholds: thresholds) == 1)
        #expect(ImmersionHeatmap.level(30, thresholds: thresholds) == 2)
        #expect(ImmersionHeatmap.level(50, thresholds: thresholds) == 3)
        #expect(ImmersionHeatmap.level(600, thresholds: thresholds) == 4)
        // A quarter-ish of the days are the lightest (under even steps of 600, all but one would be).
        #expect(year.filter { ImmersionHeatmap.level($0, thresholds: thresholds) == 1 }.count == 3)
        #expect(ImmersionHeatmap.level(60, thresholds: thresholds, busiest: 60) == 4)
        #expect(ImmersionHeatmap.thresholds([]).isEmpty && ImmersionHeatmap.level(7, thresholds: []) == 1)
    }

    /// Weeks from Sunday; the days before January 1 and after today are gaps.
    @Test func gridRunsFromTheFirstWeekToToday() {
        let days = [KechimochiDay(date: "2026-01-01", totalMinutes: 10), KechimochiDay(date: "2026-11-07", totalMinutes: 52)]
        let grid = ImmersionHeatmap(year: 2026, days: days, today: date(2026, 11, 7), calendar: calendar)
        // 2026-01-01 is a Thursday: the first week starts on Sunday 2025-12-28.
        #expect(grid.weeks.first?.first?.date == "2025-12-28")
        #expect(grid.weeks.first?.first?.isPlaceholder == true)
        #expect(grid.weeks.first?[4] == ImmersionHeatmap.Day(date: "2026-01-01", minutes: 10, level: 1, isPlaceholder: false, isToday: false))
        let today = grid.weeks.joined().first(where: \.isToday)
        #expect(today?.date == "2026-11-07" && today?.minutes == 52 && today?.level == 4)
        // 2026-11-07 is a Saturday: the last week ends today, with nothing after it.
        #expect(grid.weeks.last?.last?.date == "2026-11-07")
        #expect(grid.weeks.allSatisfy { $0.count == 7 })
        #expect(grid.monthLabels.first?.name == "Jan" && grid.monthLabels.last?.name == "Nov")
    }

    @Test func aPastYearRunsToDecember() {
        let grid = ImmersionHeatmap(year: 2025, days: [], today: date(2026, 11, 7), calendar: calendar)
        let real = grid.weeks.joined().filter { !$0.isPlaceholder }
        #expect(real.first?.date == "2025-01-01" && real.last?.date == "2025-12-31" && real.count == 365)
        #expect(real.allSatisfy { !$0.isToday })
    }

    @Test func durationsAndDates() {
        #expect(ImmersionModel.duration(2497) == "41h 37m")
        #expect(ImmersionModel.duration(1165, spaced: true) == "19 h 25 m")
        #expect(ImmersionModel.duration(183, spaced: true) == "3 h 03 m")
        #expect(ImmersionModel.duration(38) == "38 m")
        #expect(ImmersionModel.since("2026") == "2026")
        #expect(ImmersionModel.dayString(date(2026, 3, 4), calendar: calendar) == "2026-03-04")
    }
}
