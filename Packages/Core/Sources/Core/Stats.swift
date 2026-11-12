import Foundation
import GRDB

/// A stretch of reading, watching or listening in one book or episode, for the Stats tab. Activity
/// within `ActivityLog.gap` of the last extends the same row, so idle time isn't counted.
public struct ActivitySession: Codable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "activitySession"

    public enum Kind: String, Codable, Sendable {
        case reading, watching, listening

        /// Watching and listening are measured in seconds played; reading in characters and pages.
        public var isTimed: Bool { self != .reading }
    }

    public var id: Int64?
    public var kind: Kind
    /// The Kavita series id or the Jellyfin series (or movie) id.
    public var seriesKey: String
    public var seriesTitle: String
    /// The chapter or episode.
    public var itemKey: String
    public var start: Date
    public var end: Date
    /// Characters read (books), pages turned (manga), seconds watched or listened (video, audio).
    public var characters: Int
    public var pages: Int
    public var seconds: Double

    public init(id: Int64? = nil, kind: Kind, seriesKey: String, seriesTitle: String, itemKey: String, start: Date, end: Date,
                characters: Int = 0, pages: Int = 0, seconds: Double = 0) {
        self.id = id
        self.kind = kind
        self.seriesKey = seriesKey
        self.seriesTitle = seriesTitle
        self.itemKey = itemKey
        self.start = start
        self.end = end
        self.characters = characters
        self.pages = pages
        self.seconds = seconds
    }

    /// Time spent: watched seconds for video, the session's span for reading.
    public var duration: Double {
        kind.isTimed ? seconds : end.timeIntervalSince(start)
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// Where the book, chapter or episode in an `ActivityLog` entry belongs.
public struct ActivitySubject: Equatable, Sendable {
    public var kind: ActivitySession.Kind
    public var seriesKey: String
    public var seriesTitle: String
    public var itemKey: String

    public init(kind: ActivitySession.Kind, seriesKey: String, seriesTitle: String, itemKey: String) {
        self.kind = kind
        self.seriesKey = seriesKey
        self.seriesTitle = seriesTitle
        self.itemKey = itemKey
    }
}

/// Writes reading and watching activity, and counts lookups, in the app's own database.
/// Nothing is sent anywhere (kechimochi gets reading and watching from the servers).
public struct ActivityLog: Sendable {
    public let database: AppDatabase
    /// A pause longer than this starts a new session.
    public static let gap: TimeInterval = 5 * 60

    public init(database: AppDatabase) {
        self.database = database
    }

    /// Records activity at `date`: characters read, pages turned or seconds watched.
    public func record(_ subject: ActivitySubject, at date: Date = Date(), characters: Int = 0, pages: Int = 0, seconds: Double = 0) throws {
        try database.writer.write { db in
            if var open = try ActivitySession
                .filter(Column("kind") == subject.kind.rawValue && Column("itemKey") == subject.itemKey)
                .filter(Column("end") >= date.addingTimeInterval(-Self.gap))
                .order(Column("end").desc)
                .fetchOne(db) {
                open.end = max(open.end, date)
                open.characters += characters
                open.pages += pages
                open.seconds += seconds
                try open.update(db)
            } else {
                var session = ActivitySession(kind: subject.kind, seriesKey: subject.seriesKey, seriesTitle: subject.seriesTitle,
                                              itemKey: subject.itemKey, start: date, end: date,
                                              characters: characters, pages: pages, seconds: seconds)
                try session.insert(db)
            }
        }
    }

    /// One lookup (a tap that found results).
    public func recordLookup(at date: Date = Date()) throws {
        try database.writer.write { db in
            try db.execute(sql: "INSERT INTO lookupEvent (createdAt) VALUES (?)", arguments: [date])
        }
    }

    public func sessions(kind: ActivitySession.Kind, since date: Date? = nil) throws -> [ActivitySession] {
        try database.reader.read { db in
            var request = ActivitySession.filter(Column("kind") == kind.rawValue)
            if let date { request = request.filter(Column("end") >= date) }
            return try request.order(Column("start")).fetchAll(db)
        }
    }

    /// Reading speed in characters a second: this series' reading if there's enough of it,
    /// else all reading. Nil until there's at least 2,000 characters over 10 minutes.
    public func readingSpeed(seriesKey: String) throws -> Double? {
        let sessions = try self.sessions(kind: .reading).filter { $0.duration > 0 && $0.characters > 0 }
        func speed(_ sessions: [ActivitySession]) -> Double? {
            let characters = sessions.reduce(0) { $0 + $1.characters }
            let seconds = sessions.reduce(0) { $0 + $1.duration }
            return characters >= 2000 && seconds >= 600 ? Double(characters) / seconds : nil
        }
        return speed(sessions.filter { $0.seriesKey == seriesKey }) ?? speed(sessions)
    }

    /// "~6 h left", "~25 min left" for `characters` at `speed` characters a second.
    public static func timeLeft(characters: Int, speed: Double) -> String? {
        guard characters > 0, speed > 0 else { return nil }
        let minutes = Double(characters) / speed / 60
        return minutes >= 60 ? "~\(Int((minutes / 60).rounded())) h left" : "~\(max(1, Int(minutes.rounded()))) min left"
    }

    public func lookupDates(since date: Date? = nil) throws -> [Date] {
        try database.reader.read { db in
            try Date.fetchAll(db, sql: "SELECT createdAt FROM lookupEvent WHERE createdAt >= ?", arguments: [date ?? .distantPast])
        }
    }

    // MARK: Saved state

    /// Mining-deck note ids from the last time Stats reached Anki (their ids are creation times).
    public func cachedAnkiNoteIds() throws -> [Int64] {
        try database.reader.read { db in
            guard let data = try Data.fetchOne(db, sql: "SELECT ankiNoteIds FROM statsState WHERE id = 1") else { return [] }
            return (try? JSONDecoder().decode([Int64].self, from: data)) ?? []
        }
    }

    public func saveAnkiNoteIds(_ ids: [Int64]) throws {
        let data = try JSONEncoder().encode(ids)
        try database.writer.write { db in
            try db.execute(sql: """
                INSERT INTO statsState (id, ankiNoteIds) VALUES (1, ?)
                ON CONFLICT(id) DO UPDATE SET ankiNoteIds = excluded.ankiNoteIds
                """, arguments: [data])
        }
    }

    /// The user's kechimochi page (Settings ▸ Stats), opened from the Stats tab.
    public func kechimochiURL() throws -> String? {
        try database.reader.read { try String.fetchOne($0, sql: "SELECT kechimochiURL FROM statsState WHERE id = 1") }
    }

    /// The last answer kechimochi gave for `key` ("snapshot", "heatmap-2025"), for Stats ▸ All
    /// immersion offline, and when it came.
    public func kechimochiCache(_ key: String) throws -> (data: Data, fetchedAt: Date)? {
        try database.reader.read { db in
            try Row.fetchOne(db, sql: "SELECT data, fetchedAt FROM kechimochiCache WHERE key = ?", arguments: [key])
                .map { ($0["data"], $0["fetchedAt"]) }
        }
    }

    public func saveKechimochiCache(_ key: String, data: Data, at date: Date = Date()) throws {
        try database.writer.write { db in
            try db.execute(sql: """
                INSERT INTO kechimochiCache (key, data, fetchedAt) VALUES (?, ?, ?)
                ON CONFLICT(key) DO UPDATE SET data = excluded.data, fetchedAt = excluded.fetchedAt
                """, arguments: [key, data, date])
        }
    }

    public func saveKechimochiURL(_ url: String?) throws {
        try database.writer.write { db in
            try db.execute(sql: """
                INSERT INTO statsState (id, kechimochiURL) VALUES (1, ?)
                ON CONFLICT(id) DO UPDATE SET kechimochiURL = excluded.kechimochiURL
                """, arguments: [url])
        }
    }
}

/// One mined card for Stats: when, and the series it came from when known.
public struct MinedCardStat: Equatable, Sendable {
    public var date: Date
    public var seriesKey: String?
    public var seriesTitle: String?

    public init(date: Date, seriesKey: String? = nil, seriesTitle: String? = nil) {
        self.date = date
        self.seriesKey = seriesKey
        self.seriesTitle = seriesTitle
    }
}

/// The Stats tab's numbers for one period.
public struct StatsSummary: Equatable, Sendable {
    public enum Period: String, CaseIterable, Sendable {
        case week, month, allTime
    }

    public struct Bar: Equatable, Sendable, Identifiable {
        /// The day (or month, for all time) the bar covers.
        public var date: Date
        /// Characters read, or seconds watched.
        public var value: Double
        public var isCurrent: Bool
        public var id: Date { date }
    }

    public struct Series: Equatable, Sendable, Identifiable {
        public var key: String
        public var title: String
        public var characters: Int
        public var pages: Int
        public var seconds: Double
        /// Distinct chapters or episodes.
        public var items: Int
        public var cards: Int
        public var id: String { key }
    }

    public var bars: [Bar]
    /// Characters read, or seconds watched, in the period.
    public var total: Double
    public var streak: Int
    public var seconds: Double
    /// Distinct chapters or episodes in the period.
    public var items: Int
    public var cards: Int
    public var lookups: Int
    public var series: [Series]

    /// Builds the summary. `cards` are every card mined (all apps, by date) and `ownCards`
    /// the ones this app mined, for the by-series counts.
    public static func make(kind: ActivitySession.Kind, period: Period, sessions: [ActivitySession], lookups: [Date],
                            cards: [Date], ownCards: [MinedCardStat], now: Date = Date(), calendar: Calendar = .current) -> StatsSummary {
        let today = calendar.startOfDay(for: now)
        let starts: [Date]
        switch period {
        case .week: starts = (0..<7).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
        case .month: starts = (0..<30).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
        case .allTime:
            let first = sessions.map(\.start).min() ?? now
            let firstMonth = calendar.dateInterval(of: .month, for: first)?.start ?? today
            let thisMonth = calendar.dateInterval(of: .month, for: now)?.start ?? today
            var months: [Date] = []
            var month = firstMonth
            while month <= thisMonth, months.count < 240 {
                months.append(month)
                month = calendar.date(byAdding: .month, value: 1, to: month) ?? thisMonth.addingTimeInterval(1)
            }
            starts = months
        }
        let from = starts.first ?? today
        let inPeriod = sessions.filter { $0.start >= from }
        func value(_ session: ActivitySession) -> Double {
            kind.isTimed ? session.seconds : Double(session.characters)
        }
        func bucket(_ date: Date) -> Date {
            period == .allTime ? (calendar.dateInterval(of: .month, for: date)?.start ?? date) : calendar.startOfDay(for: date)
        }
        var byBucket: [Date: Double] = [:]
        for session in inPeriod { byBucket[bucket(session.start), default: 0] += value(session) }
        let current = bucket(now)
        let bars = starts.map { Bar(date: $0, value: byBucket[$0] ?? 0, isCurrent: $0 == current) }

        var series: [String: Series] = [:]
        var titles: [String: String] = [:]
        for session in inPeriod {
            var entry = series[session.seriesKey] ?? Series(key: session.seriesKey, title: session.seriesTitle, characters: 0, pages: 0,
                                                             seconds: 0, items: 0, cards: 0)
            entry.characters += session.characters
            entry.pages += session.pages
            entry.seconds += session.duration
            series[session.seriesKey] = entry
            titles[session.seriesTitle] = session.seriesKey
        }
        // Episodes count from a minute of playing, here and in the total.
        let watchedItems = inPeriod.filter { kind == .reading || $0.seconds >= 60 }
        for key in series.keys {
            series[key]?.items = Set(watchedItems.filter { $0.seriesKey == key }.map(\.itemKey)).count
        }
        for card in ownCards where card.date >= from {
            let key = card.seriesKey ?? card.seriesTitle.flatMap { titles[$0] } ?? card.seriesTitle.map { "title:\($0)" }
            guard let key else { continue }
            if series[key] == nil {
                series[key] = Series(key: key, title: card.seriesTitle ?? "", characters: 0, pages: 0, seconds: 0, items: 0, cards: 0)
            }
            series[key]?.cards += 1
        }

        return StatsSummary(
            bars: bars,
            total: inPeriod.reduce(0) { $0 + value($1) },
            streak: streak(sessions: sessions, kind: kind, now: now, calendar: calendar),
            seconds: inPeriod.reduce(0) { $0 + $1.duration },
            items: Set(watchedItems.map(\.itemKey)).count,
            cards: cards.filter { $0 >= from }.count,
            lookups: lookups.filter { $0 >= from }.count,
            series: series.values.sorted { ($0.characters, $0.seconds, $0.cards) > ($1.characters, $1.seconds, $1.cards) }
        )
    }

    /// Consecutive days with activity, ending today (or yesterday, if nothing yet today).
    static func streak(sessions: [ActivitySession], kind: ActivitySession.Kind, now: Date, calendar: Calendar) -> Int {
        let active = Set(sessions.filter { kind.isTimed ? $0.seconds >= 60 : ($0.characters > 0 || $0.pages > 0) }
            .map { calendar.startOfDay(for: $0.start) })
        var day = calendar.startOfDay(for: now)
        if !active.contains(day) { day = calendar.date(byAdding: .day, value: -1, to: day) ?? day }
        var count = 0
        while active.contains(day) {
            count += 1
            day = calendar.date(byAdding: .day, value: -1, to: day) ?? day
        }
        return count
    }
}
