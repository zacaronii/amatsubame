#if os(iOS)
import AudiobookshelfKit
import Core
import Foundation
@testable import Kiku
import KikuWatchLink
import Testing

/// Listening on the watch, applied on the phone (docs/KIKU_PLAN.md milestone 3).
@MainActor @Suite struct WatchListeningTests {
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    func environment() -> KikuEnvironment {
        let temp = URL.temporaryDirectory.appending(path: "KikuTests-\(UUID().uuidString)")
        return KikuEnvironment(database: try! AppDatabase.inMemory(), secrets: InMemorySecretStore(),
                               mediaDirectory: temp.appending(path: "Media"), dictionaryDirectory: temp.appending(path: "Dictionaries"),
                               downloadsDirectory: temp.appending(path: "Downloads"), backgroundDownloads: false, sendsProgress: false, sendsCards: false)
    }

    func stretch(seconds: Double, endingAt end: Double) -> WatchListening {
        let item = WatchItem(itemId: "show", episodeId: "ep", ino: "1", fileExtension: "mp3", title: "Episode",
                             subtitle: "Show", duration: 1800, addedAt: start)
        var stretch = WatchListening(id: "s1", item: item, position: 100, rate: 1, at: start)
        stretch.add(seconds, at: end, rate: 1, on: start.addingTimeInterval(seconds))
        return stretch
    }

    func waiting(_ environment: KikuEnvironment) throws -> [OutboxJobKind] {
        try environment.common.outbox.jobs(states: [.pending]).map(\.kind)
    }

    @Test func listeningCountsOnceAndGrowsByWhatsNew() throws {
        let environment = environment()
        let library = environment.watchLibrary
        let first = stretch(seconds: 60, endingAt: 160)
        #expect(library.apply([first], now: start.addingTimeInterval(70)) == ["s1": first.endedAt])
        var rows = try environment.common.activity.sessions(kind: .listening)
        #expect(rows.map(\.seconds) == [60] && rows.first?.itemKey == "show/ep" && rows.first?.seriesTitle == "Episode")
        // A session (the watch's id) and the place, which nothing newer has.
        #expect(Set(try waiting(environment)) == [.audiobookshelfSession, .audiobookshelfProgress])
        #expect(environment.library.progress["show/ep"]?.currentTime == 160)
        #expect(library.lastSynced == start.addingTimeInterval(70))

        // Sent again unchanged: nothing more.
        library.apply([first])
        #expect(try environment.common.activity.sessions(kind: .listening).map(\.seconds).reduce(0, +) == 60)

        // It grew: only the new 30 s count.
        let grown = stretch(seconds: 90, endingAt: 190)
        #expect(library.apply([grown])["s1"] == grown.endedAt)
        rows = try environment.common.activity.sessions(kind: .listening)
        #expect(rows.map(\.seconds).reduce(0, +) == 90)
        #expect(library.library.acknowledged["s1"] == grown.endedAt)
    }

    @Test func aNewerPlaceOnThePhoneStays() throws {
        let environment = environment()
        try environment.listenProgress.save(LocalWatchProgress(itemId: "show/ep", seriesId: "show", position: 900, duration: 1800,
                                                               updatedAt: start.addingTimeInterval(3600)))
        environment.watchLibrary.apply([stretch(seconds: 60, endingAt: 160)])
        #expect(try waiting(environment) == [.audiobookshelfSession])
        #expect(environment.library.progress["show/ep"] == nil)
    }
}
#endif
