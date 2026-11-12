import Core
import Foundation
import Testing

@Suite struct StatsTests {
    let book = ActivitySubject(kind: .reading, seriesKey: "12", seriesTitle: "そら ソラ 空 ガーデン", itemKey: "359")
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        return calendar
    }()

    func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    @Test func activityExtendsASessionUntilAPause() throws {
        let log = ActivityLog(database: try AppDatabase.inMemory())
        try log.record(book, at: date(4, 20, 0), characters: 100)
        try log.record(book, at: date(4, 20, 4), characters: 50)
        try log.record(book, at: date(4, 20, 30), characters: 10)
        let sessions = try log.sessions(kind: .reading)
        #expect(sessions.count == 2)
        #expect(sessions[0].characters == 150 && sessions[0].duration == 240)
        #expect(sessions[1].characters == 10)
    }

    @Test func summaryBarsStreakAndSeries() throws {
        let log = ActivityLog(database: try AppDatabase.inMemory())
        for day in [2, 3, 4] {
            try log.record(book, at: date(day, 20, 0), characters: day * 100)
            try log.record(book, at: date(day, 20, 3), characters: 0)
        }
        try log.record(ActivitySubject(kind: .reading, seriesKey: "5", seriesTitle: "鉄の時計", itemKey: "88"), at: date(4, 9), pages: 12)
        try log.recordLookup(at: date(4, 21))
        try log.recordLookup(at: date(1, 9))
        let summary = StatsSummary.make(
            kind: .reading, period: .week, sessions: try log.sessions(kind: .reading), lookups: try log.lookupDates(),
            cards: [date(4, 21), date(1, 1)], ownCards: [MinedCardStat(date: date(4, 21), seriesTitle: "そら ソラ 空 ガーデン")],
            now: date(4, 22), calendar: calendar)
        #expect(summary.bars.count == 7 && summary.bars.last?.isCurrent == true && summary.bars.last?.value == 400)
        #expect(summary.total == 900)
        #expect(summary.streak == 3)
        #expect(summary.seconds == 540)
        #expect(summary.lookups == 2 && summary.cards == 2)
        let sora = try #require(summary.series.first)
        #expect(sora.title == "そら ソラ 空 ガーデン" && sora.characters == 900 && sora.cards == 1 && sora.items == 1)
        #expect(summary.series.last?.pages == 12)
    }

    @Test func streakAllowsNothingYetToday() {
        let sessions = [3, 2].map { ActivitySession(kind: .watching, seriesKey: "s", seriesTitle: "S", itemKey: "e\($0)",
                                                    start: date($0, 20), end: date($0, 21), seconds: 1200) }
        let summary = StatsSummary.make(kind: .watching, period: .month, sessions: sessions, lookups: [], cards: [], ownCards: [],
                                        now: date(4, 8), calendar: calendar)
        #expect(summary.streak == 2)
        #expect(summary.items == 2 && summary.total == 2400 && summary.bars.count == 30)
    }

    @Test func readingSpeedNeedsEnoughReading() throws {
        let log = ActivityLog(database: try AppDatabase.inMemory())
        try log.record(book, at: date(4, 20, 0), characters: 100)
        try log.record(book, at: date(4, 20, 4), characters: 900)
        #expect(try log.readingSpeed(seriesKey: "12") == nil, "1,000 characters in 4 minutes isn't enough")
        for minute in stride(from: 5, through: 15, by: 2) {
            try log.record(book, at: date(4, 20, minute), characters: 400)
        }
        let speed = try #require(try log.readingSpeed(seriesKey: "12"))
        #expect(abs(speed - 3400.0 / 900) < 0.01)
        let other = ActivitySubject(kind: .reading, seriesKey: "99", seriesTitle: "New", itemKey: "1")
        try log.record(other, at: date(5, 9), characters: 50)
        #expect(try log.readingSpeed(seriesKey: "99") == speed, "a new book uses all reading")
        #expect(ActivityLog.timeLeft(characters: 90_000, speed: 4) == "~6 h left")
        #expect(ActivityLog.timeLeft(characters: 6000, speed: 4) == "~25 min left")
        #expect(ActivityLog.timeLeft(characters: 0, speed: 4) == nil)
    }

    @Test func olderBookSettingsKeepFuriganaFromTheBook() throws {
        let old = #"{"layout":"paged","fontSize":22}"#
        let settings = try JSONDecoder().decode(BookReaderSettings.self, from: Data(old.utf8))
        #expect(settings.furigana == .book && settings.fontSize == 22)
    }

    @Test func savedStateRoundTrips() throws {
        let log = ActivityLog(database: try AppDatabase.inMemory())
        try log.saveAnkiNoteIds([1_793_449_611_446])
        try log.saveKechimochiURL("https://kechimochi.example")
        #expect(try log.cachedAnkiNoteIds() == [1_793_449_611_446])
        #expect(try log.kechimochiURL() == "https://kechimochi.example")
    }

    @Test func kechimochiAnswersAreKeptWithTheirTime() throws {
        let log = ActivityLog(database: try AppDatabase.inMemory())
        let then = Date(timeIntervalSince1970: 1_794_000_000)
        #expect(try log.kechimochiCache("snapshot") == nil)
        try log.saveKechimochiCache("snapshot", data: Data("a".utf8), at: then)
        try log.saveKechimochiCache("snapshot", data: Data("b".utf8), at: then.addingTimeInterval(60))
        let cached = try #require(try log.kechimochiCache("snapshot"))
        #expect(cached.data == Data("b".utf8) && cached.fetchedAt == then.addingTimeInterval(60))
    }
}
