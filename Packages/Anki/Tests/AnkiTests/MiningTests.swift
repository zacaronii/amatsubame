@testable import Anki
import Core
import CoreTestSupport
import Dictionary
import Foundation
import Synchronization
import Testing

@Suite struct CardFormattingTests {
    @Test(arguments: [
        ("必死", "ひっし", "必死[ひっし]"),
        ("食べる", "たべる", "食[た]べる"),
        ("お茶", "おちゃ", "お 茶[ちゃ]"),
        ("取り扱い", "とりあつかい", "取[と]り 扱[あつか]い"),
        ("人々", "ひとびと", "人々[ひとびと]"),
        ("ひらがな", "ひらがな", "ひらがな"),
        ("テレビ", "てれび", "テレビ"),
        ("今日", "", "今日"),
    ])
    func furigana(expression: String, reading: String, expected: String) {
        #expect(CardFormatting.furigana(expression: expression, reading: reading) == expected)
    }

    @Test func pitchPositionMatchesYomitanNotation() {
        #expect(CardFormatting.pitchPosition(downsteps: [0]) == """
            <span class="pronunciation-downstep-notation" data-downstep-position="0" style="display:inline;">\
            <span class="pronunciation-downstep-notation-prefix">[</span><span class="pronunciation-downstep-notation-number">0</span>\
            <span class="pronunciation-downstep-notation-suffix">]</span></span>
            """)
        let two = CardFormatting.pitchPosition(downsteps: [0, 2])
        #expect(two.hasPrefix("<ol><li>") && two.hasSuffix("</li></ol>"))
        #expect(CardFormatting.pitchPosition(downsteps: []) == "")
    }

    @Test(arguments: [
        ([0], "へいわ", "平和", [String](), "heiban"),
        ([1], "いのち", "命", [], "atamadaka"),
        ([2], "おかし", "お菓子", [], "nakadaka"),
        ([3], "おとこ", "男", [], "odaka"),
        ([2], "たべる", "食べる", ["v1"], "kifuku"),
        ([2], "たかい", "高い", ["adj-i"], "kifuku"),
        ([0], "あそぶ", "遊ぶ", ["v5"], "heiban"),
        ([3], "べんきょう", "勉強", ["vs"], "nakadaka"),
        ([0, 3], "おとこ", "男", [], "heiban,odaka"),
    ])
    func pitchCategories(downsteps: [Int], reading: String, expression: String, rules: [String], expected: String) {
        #expect(CardFormatting.pitchCategories(downsteps: downsteps, expression: expression, reading: reading, rules: rules) == expected)
    }

    @Test func frequenciesUseYomitanListAndHarmonicRank() {
        let groups = [
            FrequencyGroup(dictionary: "CC100", values: [Frequency(value: 2192, display: "2192"), Frequency(value: 131072, display: "131072")]),
            FrequencyGroup(dictionary: "JPDB", values: [Frequency(value: 1994, display: "1994"), Frequency(value: 80073, display: "80073㋕")]),
        ]
        #expect(CardFormatting.frequencyList(groups) == "<ul data-content=\"frequencies\"><li data-dictionary=\"CC100\">CC100: 2192</li>"
            + "<li data-dictionary=\"CC100\">CC100: 131072</li><li data-dictionary=\"JPDB\">JPDB: 1994</li>"
            + "<li data-dictionary=\"JPDB\">JPDB: 80073㋕</li></ul>")
        // The harmonic mean of each dictionary's lowest value: FreqSort 2088.
        #expect(CardFormatting.frequencySort(groups) == "2088")
        #expect(CardFormatting.frequencySort([]) == "9999999")
        #expect(CardFormatting.frequencyList([]) == "")
    }

    @Test func sentenceBoldsTheWordAndEscapes() {
        #expect(CardFormatting.boldedSentence("なんだかすごく必死だった。", match: "必死") == "なんだかすごく<b>必死</b>だった。")
        #expect(CardFormatting.boldedSentence("a<b", match: "zz") == "a&lt;b")
    }

    @Test func glossaryUsesYomitanWrapper() {
        let html = CardFormatting.glossary([
            .init(dictionary: "Jitendex", tags: ["n", "adj-na"], html: "<span>peace</span>"),
        ])
        #expect(html == "<div style=\"text-align: left;\" class=\"yomitan-glossary\"><ol><li data-dictionary=\"Jitendex\">"
            + "<i>(n, adj-na, Jitendex)</i> <span>peace</span></li></ol></div>")
        #expect(CardFormatting.glossary([]) == "")
    }

    /// 濃厚 in JMdict: three senses become three short lines without the notes.
    @Test func shortDefinitionIsTheFirstGlossesOfTheFirstSenses() {
        let senses = [
            ["rich (flavor, color, etc.)", "strong (e.g. odor)", "heavy", "thick (soup, makeup, etc.)", "dense"],
            ["probable", "(very) likely", "strong (suspicion, sense, etc.)"],
            ["passionate", "sensuous", "hot"],
            ["unused fourth sense"],
        ]
        #expect(CardFormatting.shortDefinition(senses) == "1. rich; strong; heavy<br>2. probable; likely<br>3. passionate; sensuous; hot")
    }

    @Test func shortDefinitionOfOneSenseHasNoNumber() {
        #expect(CardFormatting.shortDefinition([["(sound of) <bells>"]]) == "&lt;bells&gt;")
        #expect(CardFormatting.shortDefinition([["(onomatopoeia)"]]) == "(onomatopoeia)", "a gloss that's all note stays")
        #expect(CardFormatting.shortDefinition([[], ["talent", "ability"]]) == "talent; ability")
        #expect(CardFormatting.shortDefinition([]) == "")
    }
}

@Suite struct AnkiNoteBuilderTests {
    let lapisFields = ["Expression", "ExpressionFurigana", "ExpressionReading", "ExpressionAudio", "MainDefinition", "SelectionText",
                       "Sentence", "SentenceAudio", "Picture", "Glossary", "IsWordAndSentenceCard", "PitchPosition", "PitchCategories",
                       "Frequency", "FreqSort", "MiscInfo"]

    var card: MinedCard {
        MinedCard(expression: "必死", reading: "ひっし", content: [
            .furigana: "必死[ひっし]", .sentence: "<b>必死</b>だった。", .mainDefinition: "<div>desperate</div>",
            .freqSort: "769", .miscInfo: "Midnight Bridge — Ch. 1, p. 3",
        ], deck: "Japanese::Mining", noteType: "Lapis", tags: ["amatsubame"])
    }

    @Test func mapsSlotsConstantsAndMediaToLapisFields() throws {
        let result = try AnkiNoteBuilder.note(
            for: card, mapping: AnkiSettings.lapisFields, fieldNames: lapisFields,
            pictureFile: "amatsubame_p.jpg", audioFile: "amatsubame_a.mp3", sentenceAudioFile: "amatsubame_s.m4a"
        )
        let note = result.note
        #expect(note.fields["Expression"] == "必死")
        #expect(note.fields["ExpressionReading"] == "ひっし")
        #expect(note.fields["Sentence"] == "<b>必死</b>だった。")
        #expect(note.fields["IsWordAndSentenceCard"] == "x")
        #expect(note.fields["FreqSort"] == "769")
        #expect(note.fields["Picture"] == "<img src=\"amatsubame_p.jpg\">")
        #expect(note.fields["ExpressionAudio"] == "[sound:amatsubame_a.mp3]")
        #expect(note.fields["SentenceAudio"] == "[sound:amatsubame_s.m4a]")
        #expect(note.deckName == "Japanese::Mining" && note.modelName == "Lapis" && note.tags == ["amatsubame"])
        #expect(result.missingFields.isEmpty)
    }

    @Test func readerCardsLeaveSentenceAudioEmpty() throws {
        let result = try AnkiNoteBuilder.note(for: card, mapping: AnkiSettings.lapisFields, fieldNames: lapisFields,
                                              pictureFile: nil, audioFile: nil)
        #expect(result.note.fields["SentenceAudio"] == "")
    }

    @Test func dropsFieldsTheNoteTypeLacks() throws {
        let result = try AnkiNoteBuilder.note(for: card, mapping: AnkiSettings.lapisFields, fieldNames: ["Expression", "Sentence"],
                                              pictureFile: "p.jpg", audioFile: nil)
        #expect(Set(result.note.fields.keys) == ["Expression", "Sentence"])
        #expect(result.missingFields.contains("Picture"))
    }

    @Test func failsWithoutAWordField() {
        #expect(throws: AnkiNoteBuilder.BuildError.noWordField) {
            try AnkiNoteBuilder.note(for: card, mapping: AnkiSettings.lapisFields, fieldNames: ["Front", "Back"], pictureFile: nil, audioFile: nil)
        }
    }

    @Test func cardPayloadRoundTrips() throws {
        let data = try JSONEncoder().encode(card)
        #expect(try JSONDecoder().decode(MinedCard.self, from: data) == card)
    }
}

@Suite struct AnkiNoteClientTests {
    let base = URL(string: "http://anki.example.ts.net:8765")!

    func fixture(_ name: String) throws -> Data { try Fixture.data(name, in: .module) }

    @Test func addNoteSendsOnlyAnkiConnectKeys() async throws {
        let response = try fixture("add-note.json")
        let stub = StubTransport { _ in (200, response) }
        let note = AnkiNote(deckName: "D", modelName: "Lapis", fields: ["Expression": "必死"], tags: ["t"], allowDuplicate: false)
        let id = try await AnkiConnectClient(baseURL: base, http: HTTPClient(transport: stub)).addNote(note)
        #expect(id == 1700000000001)

        let body = try stub.requests[0].jsonBody()
        #expect(body["action"] as? String == "addNote")
        let sent = try #require((body["params"] as? [String: Any])?["note"] as? [String: Any])
        #expect(Set(sent.keys) == ["deckName", "modelName", "fields", "tags", "options"])
        #expect(sent["options"] as? NSDictionary == ["allowDuplicate": false, "duplicateScope": "deck"] as NSDictionary)
    }

    @Test func storeMediaFileAcceptsNullOrRenamedResult() async throws {
        let proxy = StubTransport { _ in (200, Data(#"{"result":null,"error":null}"#.utf8)) }
        let stored = try await AnkiConnectClient(baseURL: base, http: HTTPClient(transport: proxy)).storeMediaFile(Data("hi".utf8), filename: "a.jpg")
        #expect(stored == "a.jpg")
        #expect(try proxy.requests[0].jsonBody()["params"] as? NSDictionary == ["filename": "a.jpg", "data": "aGk="] as NSDictionary)
        let renaming = StubTransport { _ in (200, Data(#"{"result":"a-1.jpg","error":null}"#.utf8)) }
        #expect(try await AnkiConnectClient(baseURL: base, http: HTTPClient(transport: renaming)).storeMediaFile(Data(), filename: "a.jpg") == "a-1.jpg")
    }

    @Test func duplicateAndRejectedErrorsAreClassified() async throws {
        let duplicate = try fixture("error-duplicate.json")
        await #expect(throws: AnkiAddNoteError.duplicate) {
            try await AnkiConnectClient(baseURL: base, http: HTTPClient(transport: StubTransport { _ in (200, duplicate) }))
                .addNote(AnkiNote(deckName: "D", modelName: "Lapis", fields: [:], tags: [], allowDuplicate: false))
        }
        let missing = try fixture("error-model-not-found.json")
        await #expect(throws: AnkiAddNoteError.rejected("model was not found: Lapis")) {
            try await AnkiConnectClient(baseURL: base, http: HTTPClient(transport: StubTransport { _ in (200, missing) }))
                .addNote(AnkiNote(deckName: "D", modelName: "Lapis", fields: [:], tags: [], allowDuplicate: false))
        }
    }

    @Test func readsFieldNamesAndNotes() async throws {
        let actions = ["modelFieldNames": try fixture("model-field-names.json"), "findNotes": try fixture("find-notes.json"),
                       "notesInfo": try fixture("notes-info.json")]
        let stub = StubTransport { request in
            (200, actions[try request.jsonBody()["action"] as? String ?? ""] ?? Data())
        }
        let client = AnkiConnectClient(baseURL: base, http: HTTPClient(transport: stub))
        #expect(try await client.modelFieldNames("Lapis").contains("IsWordAndSentenceCard"))
        let ids = try await client.findNotes("note:Lapis")
        let notes = try await client.notesInfo(ids)
        #expect(notes.map { $0.fields["Expression"]?.value } == ["必死", "平和"])
        #expect(try stub.requests[0].jsonBody()["params"] as? NSDictionary == ["modelName": "Lapis"] as NSDictionary)
    }
}

@Suite struct AnkiNoteHandlerTests {
    let base = URL(string: "http://anki.example.ts.net:8765")!

    func fixture(_ name: String) throws -> Data { try Fixture.data(name, in: .module) }

    func job(_ card: MinedCard) throws -> OutboxJob {
        OutboxJob(id: 1, kind: .ankiNote, payload: try JSONEncoder().encode(card), state: .inFlight,
                  nextAttemptAt: Date(), createdAt: Date(), updatedAt: Date())
    }

    let card = MinedCard(expression: "必死", reading: "ひっし", content: [.sentence: "<b>必死</b>"],
                         deck: "Japanese::Mining", noteType: "Lapis", tags: ["amatsubame"])

    func handler(
        _ addNoteResponse: Data, audio: AudioClip? = AudioClip(data: Data("mp3".utf8), fileExtension: "mp3"),
        words: MinedWordStore, stub: inout StubTransport?
    ) throws -> AnkiNoteHandler {
        let fields = try fixture("model-field-names.json")
        let transport = StubTransport { request in
            switch try request.jsonBody()["action"] as? String {
            case "modelFieldNames": (200, fields)
            case "storeMediaFile": (200, Data(#"{"result":null,"error":null}"#.utf8))
            default: (200, addNoteResponse)
            }
        }
        stub = transport
        let client = AnkiConnectClient(baseURL: base, http: HTTPClient(transport: transport))
        return AnkiNoteHandler(makeClient: { client }, settings: { .default }, fetchAudio: { _, _ in audio }, minedWords: words)
    }

    @Test func sendsCardWithPictureAndAudioAndMarksWordMined() async throws {
        let words = MinedWordStore(database: try AppDatabase.inMemory())
        var stub: StubTransport?
        let handler = try handler(try fixture("add-note.json"), words: words, stub: &stub)
        let picture = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).jpg")
        try Data("jpg".utf8).write(to: picture)
        defer { try? FileManager.default.removeItem(at: picture) }

        try await handler.send(try job(card), media: [(field: MinedCard.pictureMedia, url: picture)])

        let actions = try stub?.requests.map { try $0.jsonBody()["action"] as? String } ?? []
        #expect(actions == ["modelFieldNames", "storeMediaFile", "storeMediaFile", "addNote"])
        let note = try #require(try stub?.requests.last?.jsonBody()["params"] as? [String: Any])["note"] as? [String: Any]
        let fields = note?["fields"] as? [String: String]
        #expect(fields?["Picture"] == "<img src=\"amatsubame_\(picture.lastPathComponent.lowercased().replacingOccurrences(of: "-", with: ""))\">")
        #expect(fields?["ExpressionAudio"]
            == "[sound:\(AnkiNoteHandler.audioFilename(expression: "必死", reading: "ひっし", fileExtension: "mp3"))]")
        #expect(try words.contains(expression: "必死", reading: "ひっし"))
    }

    @Test func mediaNamesUseOnlySafeCharacters() {
        #expect(AnkiNoteHandler.mediaFilename(URL(filePath: "/tmp/A1B9-71日 43.JPG")) == "amatsubame_a1b97143.jpg")
        #expect(AnkiNoteHandler.safeFilename("Amatsubame_audio_FF.MP3") == "amatsubame_audio_ff.mp3")
    }

    @Test func videoCardsUploadSentenceAudio() async throws {
        let words = MinedWordStore(database: try AppDatabase.inMemory())
        var stub: StubTransport?
        let handler = try handler(try fixture("add-note.json"), words: words, stub: &stub)
        let clip = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).m4a")
        try Data("m4a".utf8).write(to: clip)
        defer { try? FileManager.default.removeItem(at: clip) }

        try await handler.send(try job(card), media: [(field: MinedCard.sentenceAudioMedia, url: clip)])

        let uploads = try stub?.requests.filter { try $0.jsonBody()["action"] as? String == "storeMediaFile" } ?? []
        #expect(try uploads.contains { try ($0.jsonBody()["params"] as? [String: Any])?["filename"] as? String
            == "amatsubame_\(clip.lastPathComponent.lowercased().replacingOccurrences(of: "-", with: ""))" })
        let note = try #require(try stub?.requests.last?.jsonBody()["params"] as? [String: Any])["note"] as? [String: Any]
        #expect((note?["fields"] as? [String: String])?["SentenceAudio"] == "[sound:amatsubame_\(clip.lastPathComponent.lowercased().replacingOccurrences(of: "-", with: ""))]")
    }

    @Test func sendsWithoutAudioWhenNoneIsFound() async throws {
        var stub: StubTransport?
        let handler = try handler(try fixture("add-note.json"), audio: nil,
                                  words: MinedWordStore(database: try AppDatabase.inMemory()), stub: &stub)
        try await handler.send(try job(card), media: [])
        let note = try #require(try stub?.requests.last?.jsonBody()["params"] as? [String: Any])["note"] as? [String: Any]
        #expect((note?["fields"] as? [String: String])?["ExpressionAudio"] == "")
        #expect(try stub?.requests.contains { try $0.jsonBody()["action"] as? String == "storeMediaFile" } == false)
    }

    @Test func duplicateIsPermanentAndMarksWord() async throws {
        let words = MinedWordStore(database: try AppDatabase.inMemory())
        var stub: StubTransport?
        let handler = try handler(try fixture("error-duplicate.json"), words: words, stub: &stub)
        await #expect(throws: OutboxPermanentFailure.self) { try await handler.send(try job(card), media: []) }
        #expect(try words.contains(expression: "必死", reading: "ひっし"))
    }

    @Test func rejectedNoteIsPermanent() async throws {
        var stub: StubTransport?
        let handler = try handler(try fixture("error-model-not-found.json"),
                                  words: MinedWordStore(database: try AppDatabase.inMemory()), stub: &stub)
        await #expect(throws: OutboxPermanentFailure.self) { try await handler.send(try job(card), media: []) }
    }

    @Test func unreachableServerIsRetried() async throws {
        let transport = StubTransport { _ in throw URLError(.notConnectedToInternet) }
        let client = AnkiConnectClient(baseURL: base, http: HTTPClient(transport: transport))
        let handler = AnkiNoteHandler(makeClient: { client }, settings: { .default }, fetchAudio: { _, _ in nil },
                                      minedWords: MinedWordStore(database: try AppDatabase.inMemory()))
        do {
            try await handler.send(try job(card), media: [])
            Issue.record("expected an error")
        } catch {
            #expect(!(error is OutboxPermanentFailure))
        }
    }
}

@Suite struct AnkiSyncSchedulerTests {
    let base = URL(string: "http://anki.example.ts.net:8765")!

    func client(_ responses: [String]) -> (AnkiConnectClient, StubTransport) {
        let queue = Mutex(responses)
        let stub = StubTransport { _ in
            (200, Data(queue.withLock { $0.isEmpty ? #"{"result":null,"error":null}"# : $0.removeFirst() }.utf8))
        }
        return (AnkiConnectClient(baseURL: base, http: HTTPClient(transport: stub)), stub)
    }

    @Test func aBurstOfCardsSyncsOnce() async throws {
        let (client, stub) = client([])
        let scheduler = AnkiSyncScheduler(delay: .milliseconds(50), makeClient: { client }, isEnabled: { true })
        await scheduler.cardAdded()
        await scheduler.cardAdded()
        await scheduler.cardAdded()
        try await Task.sleep(for: .milliseconds(400))
        #expect(stub.requests.count == 1)
        #expect(try stub.requests[0].jsonBody() as NSDictionary == ["action": "sync", "version": 6] as NSDictionary)
        if case .synced = await scheduler.lastOutcome {} else { Issue.record("expected a sync") }
    }

    /// Some AnkiConnect proxies answer sync with a status report instead of null.
    @Test func aSyncReportCountsAsSynced() async throws {
        let (client, _) = client([#"{"result":[["status","completed"],["collection",[["outcome","no_changes"]]]],"error":null}"#])
        let scheduler = AnkiSyncScheduler(makeClient: { client }, isEnabled: { true })
        if case .synced = await scheduler.syncNow() {} else { Issue.record("expected a sync") }
    }

    @Test func doesNothingWhenTurnedOff() async throws {
        let (client, stub) = client([])
        let scheduler = AnkiSyncScheduler(delay: .milliseconds(10), makeClient: { client }, isEnabled: { false })
        await scheduler.cardAdded()
        try await Task.sleep(for: .milliseconds(100))
        #expect(stub.requests.isEmpty)
    }

    @Test func retriesOnceWhenASyncIsAlreadyRunning() async throws {
        let (client, stub) = client([#"{"result":null,"error":"A synchronization is already in progress"}"#])
        let scheduler = AnkiSyncScheduler(busyRetryDelay: .milliseconds(10), makeClient: { client }, isEnabled: { true })
        let outcome = await scheduler.syncNow()
        #expect(stub.requests.count == 2)
        if case .synced = outcome {} else { Issue.record("expected the retry to sync, got \(outcome)") }
    }

    @Test func settingsFromBeforeTheSyncOptionDecode() throws {
        let old = #"{"deck":"D","noteType":"Lapis","fields":{},"tags":[],"pictureMaxPixels":1200}"#
        let settings = try JSONDecoder().decode(AnkiSettings.self, from: Data(old.utf8))
        #expect(settings.pictureMaxPixels == 1200 && !settings.syncAfterAdding)
    }
}
