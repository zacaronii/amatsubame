import Core
import Foundation
import Testing

@Suite struct WatchProgressTests {
    let day = Date(timeIntervalSince1970: 1_793_400_000)

    func local(_ position: Double, at date: Date, duration: Double = 1420) -> LocalWatchProgress {
        LocalWatchProgress(itemId: "E", seriesId: "S", position: position, duration: duration, updatedAt: date)
    }

    @Test func newerSideWins() {
        // Watched further on this device than Jellyfin knows (report still queued).
        #expect(LocalWatchProgress.resumePosition(local: local(300, at: day), server: 120, serverDate: day.addingTimeInterval(-60)) == 300)
        // Watched elsewhere since.
        #expect(LocalWatchProgress.resumePosition(local: local(300, at: day), server: 900, serverDate: day.addingTimeInterval(60)) == 900)
        #expect(LocalWatchProgress.resumePosition(local: nil, server: 45, serverDate: nil) == 45)
        #expect(LocalWatchProgress.resumePosition(local: local(80, at: day), server: nil, serverDate: nil) == 80)
        #expect(LocalWatchProgress.resumePosition(local: nil, server: nil, serverDate: nil) == 0)
    }

    @Test func finishedStartsOver() {
        #expect(LocalWatchProgress.resumePosition(local: local(1410, at: day), server: nil, serverDate: nil) == 0)
    }

    @Test func storesRoundTrip() throws {
        let database = try AppDatabase.inMemory()
        let store = WatchProgressStore(database: database)
        try store.save(local(10, at: day))
        try store.save(local(20, at: day))
        #expect(try store.progress(itemId: "E")?.position == 20)
        #expect(try store.progress(itemId: "X") == nil)

        let visibility = JellyfinLibraryVisibilityStore(database: database)
        try visibility.setHidden("movies", hidden: true)
        try visibility.setHidden("movies", hidden: true)
        try visibility.setHidden("anime", hidden: false)
        let count = try database.reader.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM hiddenJellyfinLibrary") }
        #expect(count == 1)
    }
}

@Suite struct AnkiSettingsUpgradeTests {
    @Test func savedLapisMappingGainsSentenceAudio() throws {
        var old = AnkiSettings.default
        old.fields["SentenceAudio"] = nil
        let decoded = try JSONDecoder().decode(AnkiSettings.self, from: JSONEncoder().encode(old))
        #expect(decoded.fields["SentenceAudio"] == .slot(.sentenceAudio))

        var other = AnkiSettings(deck: "d", noteType: "Basic", fields: ["Front": .slot(.expression)], tags: [])
        other = try JSONDecoder().decode(AnkiSettings.self, from: JSONEncoder().encode(other))
        #expect(other.fields["SentenceAudio"] == nil)
    }

    @Test func segmentsAreReplacedPerItem() throws {
        let store = MediaSegmentStore(database: try AppDatabase.inMemory())
        try store.save([CachedMediaSegment(itemId: "E", kind: "Outro", start: 1400, end: 1500),
                        CachedMediaSegment(itemId: "E", kind: "Intro", start: 0, end: 90)], itemId: "E")
        try store.save([CachedMediaSegment(itemId: "F", kind: "Intro", start: 10, end: 80)], itemId: "F")
        #expect(try store.segments(itemId: "E").map(\.kind) == ["Intro", "Outro"])
        try store.save([], itemId: "E")
        #expect(try store.segments(itemId: "E").isEmpty)
        #expect(try store.segments(itemId: "F").count == 1)
    }

    @Test func playerSettingsDefaultToButtons() throws {
        let database = try AppDatabase.inMemory()
        #expect(PlayerSettings.load(database).autoSkipsIntros == false)
        #expect(PlayerSettings.load(database).cardPicture == .screenshot)
        try PlayerSettings(autoSkipsIntros: true, cardPicture: .animated).save(database)
        #expect(PlayerSettings.load(database).autoSkipsIntros)
        #expect(PlayerSettings.load(database).cardPicture == .animated)
    }

    @Test func japaneseOnlyLibrariesAndAudioChecks() async throws {
        let day = Date(timeIntervalSince1970: 1_793_400_000)
        let database = try AppDatabase.inMemory()
        let visibility = JellyfinLibraryVisibilityStore(database: database)
        try visibility.setJapaneseOnly("movies", true)
        try visibility.setJapaneseOnly("movies", true)
        try visibility.setJapaneseOnly("shows", true)
        try visibility.setJapaneseOnly("shows", false)
        var values = visibility.observeJapaneseOnly().makeAsyncIterator()
        #expect(try await values.next() == ["movies"])

        let checks = JellyfinAudioCheckStore(database: database)
        try checks.save([JellyfinAudioCheck(itemId: "A", hasJapanese: true, checkedAt: day),
                         JellyfinAudioCheck(itemId: "B", hasJapanese: false, checkedAt: day.addingTimeInterval(-40 * 86400))])
        // B is too old, C was never checked.
        #expect(try checks.answers(for: ["A", "B", "C"], now: day) == ["A": true])
        try checks.save([JellyfinAudioCheck(itemId: "B", hasJapanese: true, checkedAt: day)])
        #expect(try checks.answers(for: ["A", "B"], now: day) == ["A": true, "B": true])
    }
}
