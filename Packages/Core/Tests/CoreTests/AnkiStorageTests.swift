import Core
import Foundation
import Testing

@Suite struct OutboxCardEditingTests {
    let clock = TestClock()
    let store: OutboxStore

    init() throws {
        let clock = clock
        store = OutboxStore(database: try AppDatabase.inMemory(), now: { clock.now })
    }

    @Test func notBeforeHoldsTheJobBack() throws {
        let id = try store.enqueue(Card(expression: "必死"), kind: .ankiNote, notBefore: clock.now.addingTimeInterval(5))
        #expect(try store.claimDueJobs(kinds: [.ankiNote]).isEmpty)
        #expect(try store.nextAttemptDate(kinds: [.ankiNote]) == clock.now.addingTimeInterval(5))
        clock.advance(5)
        #expect(try store.claimDueJobs(kinds: [.ankiNote]).map(\.job.id) == [id])
    }

    @Test func retryWaitingNowSkipsTheUndoWindow() throws {
        let failed = try store.enqueue(Card(expression: "a"), kind: .ankiNote)
        _ = try store.claimDueJobs(kinds: [.ankiNote])
        try store.markRetry(failed, error: "offline")
        let fresh = try store.enqueue(Card(expression: "b"), kind: .ankiNote, notBefore: clock.now.addingTimeInterval(5))
        #expect(try store.retryWaitingNow() == 1)
        #expect(try store.claimDueJobs(kinds: [.ankiNote]).map(\.job.id) == [failed])
        #expect(try store.job(fresh)?.job.state == .pending)
    }

    @Test func cancelDeletesUnsentJobsAndReturnsMedia() throws {
        let id = try store.enqueue(Card(expression: "必死"), kind: .ankiNote, media: [OutboxMediaInput(field: "picture", filename: "p.jpg")])
        #expect(try store.cancel(id) == ["p.jpg"])
        #expect(try store.job(id) == nil)
        #expect(try store.summary() == .empty)
    }

    @Test func cancelLeavesInFlightAndSentJobsAlone() throws {
        let id = try store.enqueue(Card(expression: "必死"), kind: .ankiNote)
        _ = try store.claimDueJobs(kinds: [.ankiNote])
        #expect(try store.cancel(id) == nil)
        try store.markSent(id)
        #expect(try store.cancel(id) == nil)
        #expect(try store.job(id)?.job.state == .sent)
    }

    @Test func updatePayloadEditsUnsentJobsOnly() throws {
        let id = try store.enqueue(Card(expression: "必死"), kind: .ankiNote)
        #expect(try store.updatePayload(id, payload: JSONEncoder().encode(Card(expression: "平和"))))
        #expect(try store.job(id)?.job.decodePayload(Card.self) == Card(expression: "平和"))
        _ = try store.claimDueJobs(kinds: [.ankiNote])
        #expect(try !store.updatePayload(id, payload: JSONEncoder().encode(Card(expression: "x"))))
    }
}

@Suite struct AnkiSettingsTests {
    @Test func defaultsToLapisInTheMiningDeck() throws {
        let store = AnkiSettingsStore(database: try AppDatabase.inMemory())
        let settings = try store.settings()
        #expect(settings.deck == "日本語::Mining")
        #expect(settings.noteType == "Lapis")
        #expect(settings.fields["IsWordAndSentenceCard"] == .constant("x"))
        #expect(settings.fields["Expression"] == .slot(.expression))
    }

    @Test func savedSettingsRoundTrip() throws {
        let store = AnkiSettingsStore(database: try AppDatabase.inMemory())
        var settings = AnkiSettings.default
        settings.deck = "Test"
        settings.fields["Hint"] = .slot(.reading)
        try store.save(settings)
        #expect(try store.settings() == settings)
    }

    /// Older Lapis settings gain SelectionText once; choosing Nothing for it afterwards sticks.
    @Test func olderLapisSettingsGainTheShortDefinitionOnce() throws {
        let old = #"{"deck":"日本語::Mining","noteType":"Lapis","tags":[],"fields":{"MainDefinition":{"slot":{"_0":"mainDefinition"}}}}"#
        var settings = try JSONDecoder().decode(AnkiSettings.self, from: Data(old.utf8))
        #expect(settings.fields["SelectionText"] == .slot(.shortDefinition))
        settings.fields["SelectionText"] = nil
        let saved = try JSONDecoder().decode(AnkiSettings.self, from: JSONEncoder().encode(settings))
        #expect(saved.fields["SelectionText"] == nil)
    }

    @Test func presetUsesLapisNamesThatExist() {
        let fields = AnkiSettings.presetFields(for: ["Expression", "Sentence", "Picture", "Other"])
        #expect(fields == ["Expression": .slot(.expression), "Sentence": .slot(.sentence), "Picture": .slot(.picture)])
    }

    @Test func presetFallsBackToFirstFieldForOtherNoteTypes() {
        #expect(AnkiSettings.presetFields(for: ["Front", "Back"]) == ["Front": .slot(.expression)])
    }
}

@Suite struct MinedWordStoreTests {
    let store: MinedWordStore

    init() throws {
        store = MinedWordStore(database: try AppDatabase.inMemory())
    }

    @Test func queuedWordsAreMarkedUntilCancelled() throws {
        try store.markQueued(expression: "必死", reading: "ひっし", jobId: 7)
        #expect(try store.contains(expression: "必死", reading: "ひっし"))
        #expect(try !store.contains(expression: "必死", reading: "ひつし"))
        try store.removeQueued(jobId: 7)
        #expect(try !store.contains(expression: "必死", reading: "ひっし"))
    }

    @Test func ankiWordWithoutReadingMatchesAnyReading() throws {
        try store.replaceAnkiWords([("平和", "", false)])
        #expect(try store.contains(expression: "平和", reading: "へいわ"))
    }

    @Test func refreshReplacesAnkiWordsButKeepsQueuedOnes() throws {
        try store.replaceAnkiWords([("平和", "へいわ", false)])
        try store.markQueued(expression: "必死", reading: "ひっし", jobId: 1)
        try store.replaceAnkiWords([("戦争", "せんそう", true)])
        #expect(try !store.contains(expression: "平和", reading: "へいわ"))
        #expect(try store.contains(expression: "戦争", reading: "せんそう"))
        #expect(try store.contains(expression: "必死", reading: "ひっし"))
    }

    @Test func otherDecksAreMarkedButNotMined() throws {
        try store.replaceAnkiWords([("戦争", "せんそう", false)], others: [("戦争", "", true), ("平和", "", false)])
        let marks = try store.marks()
        #expect(marks.state(expression: "戦争", reading: "せんそう") == .known, "known in either deck")
        #expect(marks.state(expression: "平和", reading: "へいわ") == .learning)
        #expect(try store.contains(expression: "戦争", reading: "せんそう"))
        #expect(try !store.contains(expression: "平和", reading: "へいわ"), "other decks aren't the mining deck")
        try store.replaceAnkiWords([])
        #expect(try store.marks().state(expression: "平和", reading: "へいわ") == .notInAnki)
    }

    @Test func marksTellNewLearningAndKnownWordsApart() throws {
        try store.replaceAnkiWords([("戦争", "せんそう", true), ("平和", "", false)])
        try store.markQueued(expression: "必死", reading: "ひっし", jobId: 1)
        let marks = try store.marks()
        #expect(marks.state(expression: "戦争", reading: "せんそう") == .known)
        #expect(marks.state(expression: "平和", reading: "へいわ") == .learning, "an empty reading in Anki matches any")
        #expect(marks.state(expression: "必死", reading: "ひっし") == .learning, "queued words are learning")
        #expect(marks.state(expression: "必死", reading: "ひつし") == .notInAnki)
        #expect(marks.state(expression: "猫", reading: "ねこ") == .notInAnki)
        try store.markInAnki(expression: "戦争", reading: "せんそう")
        #expect(try store.marks().state(expression: "戦争", reading: "せんそう") == .known, "a duplicate stays known")
    }

    @Test func sentCardBecomesAnAnkiWordAndSurvivesCancelCleanup() throws {
        try store.markQueued(expression: "必死", reading: "ひっし", jobId: 1)
        try store.markInAnki(expression: "必死", reading: "ひっし")
        try store.removeQueued(jobId: 1)
        #expect(try store.contains(expression: "必死", reading: "ひっし"))
    }
}

@Suite struct BookStorageTests {
    @Test func bookSettingsRoundTripPerSeriesWithDefault() throws {
        let store = BookReaderSettingsStore(database: try AppDatabase.inMemory())
        #expect(try store.settings(seriesId: 34) == .default)
        var settings = BookReaderSettings()
        settings.fontSize = 24
        try store.saveAsDefault(settings)
        #expect(try store.settings(seriesId: 34).fontSize == 24)
        settings.theme = .sepia
        try store.save(settings, seriesId: 34)
        #expect(try store.settings(seriesId: 34).theme == .sepia)
        #expect(try store.settings(seriesId: 1).theme == .system)
    }

    @Test func olderBookSettingsKeepNewDefaults() throws {
        let settings = try JSONDecoder().decode(BookReaderSettings.self, from: Data(#"{"fontSize":18}"#.utf8))
        #expect(settings.fontSize == 18 && settings.layout == .paged)
    }

    @Test func progressTextReplacesTheOldSwitch() throws {
        let old = try JSONDecoder().decode(BookReaderSettings.self, from: Data(#"{"showsProgress":true}"#.utf8))
        #expect(old.progressText == .always && old.showsProgressBar)
        let hidden = try JSONDecoder().decode(BookReaderSettings.self, from: Data(#"{"showsProgress":false}"#.utf8))
        #expect(hidden.progressText == .hidden)
        var settings = BookReaderSettings()
        settings.progressText = .hidden
        settings.showsProgressBar = false
        #expect(try JSONDecoder().decode(BookReaderSettings.self, from: JSONEncoder().encode(settings)) == settings)
    }

    @Test func librariesCanBeHiddenAndShown() throws {
        let store = LibraryVisibilityStore(database: try AppDatabase.inMemory())
        try store.setHidden(2, hidden: true)
        try store.setHidden(2, hidden: true)
        try store.setHidden(4, hidden: true)
        try store.setHidden(4, hidden: false)
        #expect(try store.hiddenLibraryIds() == [2])
    }

    @Test func progressKeepsScrollPosition() throws {
        let store = ReadingProgressStore(database: try AppDatabase.inMemory())
        let progress = LocalReadingProgress(chapterId: 359, seriesId: 34, volumeId: 359, libraryId: 4, page: 5, pages: 46,
                                            updatedAt: Date(timeIntervalSince1970: 1_800_000_000), scrollId: "//body/div[1]/p[3]")
        try store.save(progress)
        #expect(try store.progress(chapterId: 359) == progress)
    }
}
