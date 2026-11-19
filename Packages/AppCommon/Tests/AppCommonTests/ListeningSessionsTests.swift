import AudiobookshelfKit
@testable import AppCommon
import Core
import Foundation
import Testing

@MainActor @Suite struct ListeningSessionsTests {
    final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
    }

    static let device = AudiobookshelfDeviceInfo(deviceId: "device", clientName: "Kiku", clientVersion: "0.4.0", model: "iPhone16,2")
    static let episode = ListenedItem(itemId: "li", episodeId: "ep", title: "Episode", duration: 600)

    func sessions(_ outbox: OutboxStore) throws -> [AudiobookshelfSessionPayload] {
        try outbox.jobs(states: [.pending]).filter { $0.kind == .audiobookshelfSession }
            .map { try $0.decodePayload(AudiobookshelfSessionPayload.self) }
    }

    @Test func listeningIsOneSessionUntilALongPause() throws {
        let clock = Clock()
        let outbox = OutboxStore(database: try AppDatabase.inMemory())
        let reporter = ListeningSessionReporter(outbox: outbox, device: Self.device, syncNow: {}, now: { clock.now })
        reporter.listened(10, item: Self.episode, position: 110)
        clock.now += 10
        reporter.listened(10, item: Self.episode, position: 120)
        // A short pause: the same session.
        clock.now += 120
        reporter.listened(10, item: Self.episode, position: 130)
        reporter.send()
        var queued = try sessions(outbox)
        #expect(queued.count == 1)
        #expect(queued[0].timeListening == 30)
        #expect(queued[0].startTime == 100)
        #expect(queued[0].currentTime == 130)
        #expect(queued[0].episodeId == "ep")
        #expect(queued[0].mediaType == "podcast")
        #expect(queued[0].deviceInfo.clientName == "Kiku")
        // Longer than the Stats gap: a new session.
        clock.now += ActivityLog.gap + 1
        reporter.listened(10, item: Self.episode, position: 140)
        reporter.send()
        queued = try sessions(outbox)
        #expect(queued.count == 2)
        #expect(Set(queued.map(\.id)).count == 2)
    }

    @Test func anotherItemStartsANewSession() throws {
        let clock = Clock()
        let outbox = OutboxStore(database: try AppDatabase.inMemory())
        let reporter = ListeningSessionReporter(outbox: outbox, device: Self.device, syncNow: {}, now: { clock.now })
        reporter.listened(10, item: Self.episode, position: 10)
        reporter.listened(10, item: ListenedItem(itemId: "book", episodeId: "", duration: 9000), position: 10)
        reporter.send()
        let queued = try sessions(outbox)
        #expect(queued.count == 2)
        let book = try #require(queued.first { $0.libraryItemId == "book" })
        #expect(book.episodeId == nil)
        #expect(book.mediaType == "book")
    }

    @Test func backfillMakesTheSameSessionsEachTimeDatedAtTheirStart() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let rows = [
            ActivitySession(id: 7, kind: .listening, seriesKey: "li", seriesTitle: "Show", itemKey: "li/ep",
                            start: start, end: start + 900, seconds: 840),
            ActivitySession(id: 8, kind: .listening, seriesKey: "book", seriesTitle: "Book", itemKey: "book",
                            start: start + 3600, end: start + 4000, seconds: 0.5),
        ]
        let place: (String) -> (position: Double, duration: Double)? = { $0 == "li/ep" ? (500, 1200) : nil }
        let first = ListeningSessionBackfill.sessions(rows, device: Self.device, position: place)
        let again = ListeningSessionBackfill.sessions(rows, device: Self.device, position: place)
        #expect(first == again)
        // Under a second of listening isn't a session.
        #expect(first.count == 1)
        #expect(first[0].timeListening == 840)
        #expect(first[0].updatedAt == first[0].startedAt)
        #expect(first[0].currentTime == 500)
        #expect(UUID(uuidString: first[0].id) != nil)
    }

    @Test func backfillLeavesOutListeningReportedAsItHappened() throws {
        let defaults = try #require(UserDefaults(suiteName: "ListeningSessionsTests.\(UUID())"))
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let outbox = OutboxStore(database: try AppDatabase.inMemory())
        _ = ListeningSessionReporter(outbox: outbox, device: Self.device, syncNow: {}, now: { start + 1000 }, defaults: defaults)
        // A later reporter (the next launch) keeps the first time.
        _ = ListeningSessionReporter(outbox: outbox, device: Self.device, syncNow: {}, now: { start + 9000 }, defaults: defaults)
        let since = try #require(defaults.object(forKey: ListeningSessionBackfill.sinceKey) as? Date)
        #expect(since == start + 1000)
        let rows = [
            ActivitySession(id: 1, kind: .listening, seriesKey: "li", seriesTitle: "Show", itemKey: "li/ep",
                            start: start, end: start + 600, seconds: 600),
            ActivitySession(id: 2, kind: .listening, seriesKey: "li", seriesTitle: "Show", itemKey: "li/ep",
                            start: start + 2000, end: start + 2600, seconds: 600),
        ]
        let queued = ListeningSessionBackfill.sessions(rows, before: since, device: Self.device) { _ in nil }
        #expect(queued.count == 1)
        #expect(queued[0].startedAt == 1_800_000_000_000)
    }
}
