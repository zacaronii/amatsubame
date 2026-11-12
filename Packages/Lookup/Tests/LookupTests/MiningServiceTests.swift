import Anki
import Core
import CoreTestSupport
import CoreGraphics
import Dictionary
import Foundation
import ImageIO
@testable import Lookup
import Testing
import UniformTypeIdentifiers

struct StubContext: MiningContext {
    var picture: Data?
    var miscInfo: String
    var seriesKey: String?
    var seriesTitle: String?
    func pictureData() async -> Data? { picture }
}

/// Records what the service reports back once the card is queued.
final class MinedRecorder: @unchecked Sendable {
    var mined: [MiningService.Mined] = []
}

struct ReportingContext: MiningContext {
    let recorder: MinedRecorder
    var miscInfo = "Show — Episode · 13:19"
    func pictureData() async -> Data? { nil }
    func mined(_ mined: MiningService.Mined) async { recorder.mined.append(mined) }
}

/// A video-like context whose clip failed.
struct FailedClipContext: MiningContext {
    var miscInfo = "Show — S1E1 · 0:47"
    func pictureData() async -> Data? { nil }
    func cardMedia() async -> CardMedia { CardMedia(picture: nil, audio: nil, problems: ["No picture: The clip came out empty."]) }
}

/// A video context whose picture is an animated GIF.
struct AnimatedClipContext: MiningContext {
    var gif: Data
    var miscInfo = "Show — S1E1 · 0:47"
    func pictureData() async -> Data? { nil }
    func cardMedia() async -> CardMedia { CardMedia(picture: gif, pictureIsAnimated: true, audio: nil) }
}

@MainActor @Suite struct MiningServiceTests {
    let database: AppDatabase
    let mediaDirectory = FileManager.default.temporaryDirectory.appending(path: "mining-\(UUID().uuidString)")
    let service: MiningService

    init() throws {
        database = try AppDatabase.inMemory()
        service = MiningService(
            outbox: OutboxStore(database: database), media: OutboxMediaStorage(directory: mediaDirectory),
            settings: AnkiSettingsStore(database: database), minedWords: MinedWordStore(database: database)
        )
    }

    static let hisshi = TermLookupResult(
        matched: "必死", deinflected: "必死", expression: "必死", reading: "ひっし", rules: [],
        glossaries: [
            Glossary(dictionary: "Jitendex", json: #"["desperate","frantic"]"#, definitionTags: ["adj-na"]),
            Glossary(dictionary: "Jitendex", json: #"["certain death"]"#, definitionTags: ["n"]),
            Glossary(dictionary: "新和英", json: #"[{"type":"structured-content","content":[{"tag":"img","path":"a.png"},"必死の"]}]"#),
        ],
        frequencies: [FrequencyGroup(dictionary: "JPDB", values: [Frequency(value: 769, display: "769"), Frequency(value: 50593, display: "50593㋕")])],
        pitches: [PitchGroup(dictionary: "Kanjium", accents: [PitchAccent(downstep: 0)])]
    )

    static func png(width: Int, height: Int) -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    @Test func cardMatchesTheLapisFormat() {
        let card = MiningService.card(for: Self.hisshi, sentence: "なんだかすごく必死だった。", miscInfo: "Midnight Bridge — Ch. 1, p. 3",
                                      settings: .default, allowDuplicate: false)
        #expect(card.deck == "日本語::Mining" && card.noteType == "Lapis" && card.tags == ["amatsubame"])
        #expect(card.content[.furigana] == "必死[ひっし]")
        #expect(card.content[.sentence] == "なんだかすごく<b>必死</b>だった。")
        #expect(card.content[.pitchCategories] == "heiban")
        #expect(card.content[.freqSort] == "769")
        #expect(card.content[.miscInfo] == "Midnight Bridge — Ch. 1, p. 3")
        let main = card.content[.mainDefinition] ?? ""
        #expect(main.hasPrefix("<div style=\"text-align: left;\" class=\"yomitan-glossary\"><ol><li data-dictionary=\"Jitendex\"><i>(adj-na, Jitendex)</i>"))
        #expect(main.contains("certain death") && !main.contains("新和英"), "main definition is the first dictionary only")
        let glossary = card.content[.glossary] ?? ""
        #expect(glossary.contains("新和英") && glossary.contains("必死の"))
        #expect(!glossary.contains("dictmedia"), "dictionary images don't load in Anki")
        #expect(card.content[.shortDefinition] == "1. desperate; frantic<br>2. certain death")
    }

    /// A prose dictionary first (no gloss lists) leaves the short definition to the next one.
    @Test func shortDefinitionSkipsDictionariesWithoutGlosses() {
        var result = Self.hisshi
        result.glossaries = [result.glossaries[2], result.glossaries[1]]
        let card = MiningService.card(for: result, sentence: nil, miscInfo: nil, settings: .default, allowDuplicate: false)
        #expect(card.content[.shortDefinition] == "certain death")
    }

    /// JMdict's forms entry (its spellings) isn't a meaning.
    @Test func shortDefinitionSkipsTheFormsEntry() {
        var result = Self.hisshi
        result.glossaries = [result.glossaries[0], Glossary(dictionary: "Jitendex", json: #"["必死（★）","必至（🅁）"]"#, definitionTags: ["forms"])]
        let card = MiningService.card(for: result, sentence: nil, miscInfo: nil, settings: .default, allowDuplicate: false)
        #expect(card.content[.shortDefinition] == "desperate; frantic")
    }

    /// The mining deck's notes, and which have a card with an interval of 21 days or more.
    @Test func refreshReadsTheDeckAndWhichWordsAreKnown() async throws {
        let notes = #"{"result":[{"noteId":1,"modelName":"Lapis","fields":{"Expression":{"value":"<b>食[た]べる</b>","order":0},"ExpressionReading":{"value":"たべる","order":1}}},{"noteId":2,"modelName":"Lapis","fields":{"Expression":{"value":"戦争","order":0},"ExpressionReading":{"value":"せんそう","order":1}}},{"noteId":3,"modelName":"Lapis","fields":{"Expression":{"value":" お 茶[ちゃ]","order":0},"ExpressionReading":{"value":"","order":1}}}],"error":null}"#
        let stub = StubTransport { request in
            let body = try request.jsonBody()
            switch body["action"] as? String {
            case "findNotes":
                let query = (body["params"] as? [String: Any])?["query"] as? String ?? ""
                return (200, Data((query.hasSuffix("prop:ivl>=21") ? #"{"result":[2],"error":null}"# : #"{"result":[1,2,3],"error":null}"#).utf8))
            case "notesInfo": return (200, Data(notes.utf8))
            default: return (200, Data(#"{"result":null,"error":"unsupported"}"#.utf8))
            }
        }
        let client = AnkiConnectClient(baseURL: URL(string: "http://anki.test")!, http: HTTPClient(transport: stub))
        try await service.refreshMinedWords(using: client)
        let queries = try stub.requests.compactMap { try ($0.jsonBody()["params"] as? [String: Any])?["query"] as? String }
        #expect(queries == [#"deck:"日本語::Mining""#, #"deck:"日本語::Mining" prop:ivl>=21"#])
        let marks = service.wordMarks()
        #expect(marks.state(expression: "食べる", reading: "たべる") == .learning)
        #expect(marks.state(expression: "戦争", reading: "せんそう") == .known)
        #expect(marks.state(expression: "お茶", reading: "おちゃ") == .learning)
        #expect(marks.state(expression: "猫", reading: "ねこ") == .notInAnki)
    }

    /// Other decks count their studied notes by the first field; never-studied ones aren't read.
    @Test func refreshAddsStudiedNotesFromOtherDecks() async throws {
        var settings = AnkiSettings.default
        settings.markDecks = ["日本語::Core 2k"]
        try AnkiSettingsStore(database: database).save(settings)
        let coreDeck = #"{"result":[{"noteId":7,"modelName":"Core 2k","fields":{"Word Reading":{"value":"ねこ","order":1},"Word":{"value":"猫","order":0}}}],"error":null}"#
        let stub = StubTransport { request in
            let body = try request.jsonBody()
            let params = body["params"] as? [String: Any]
            switch body["action"] as? String {
            case "findNotes":
                let query = params?["query"] as? String ?? ""
                if query == #"deck:"日本語::Core 2k" -is:new"# { return (200, Data(#"{"result":[7],"error":null}"#.utf8)) }
                return (200, Data(#"{"result":[],"error":null}"#.utf8))
            case "notesInfo":
                let ids = params?["notes"] as? [Int] ?? []
                return (200, Data((ids == [7] ? coreDeck : #"{"result":[],"error":null}"#).utf8))
            default: return (200, Data(#"{"result":null,"error":"unsupported"}"#.utf8))
            }
        }
        try await service.refreshMinedWords(using: AnkiConnectClient(baseURL: URL(string: "http://anki.test")!, http: HTTPClient(transport: stub)))
        #expect(service.wordMarks().state(expression: "猫", reading: "ねこ") == .learning)
        #expect(!service.isMined(TermLookupResult(matched: "猫", deinflected: "猫", expression: "猫", reading: "ねこ", rules: [],
                                                  glossaries: [], frequencies: [], pitches: [])))
    }

    @Test func cardsRememberTheirSeriesForStats() async throws {
        defer { try? FileManager.default.removeItem(at: mediaDirectory) }
        let mined = try await service.mine(Self.hisshi, sentence: "必死だ",
                                           context: StubContext(miscInfo: "Src", seriesKey: "12", seriesTitle: "そら"))
        let card = try #require(try OutboxStore(database: database).job(mined.jobId)).job.decodePayload(MinedCard.self)
        #expect(card.seriesKey == "12" && card.seriesTitle == "そら")
    }

    /// Kiku's marks: the context hears about the card, and Undo is reported with its job.
    @Test func contextHearsTheCardAndUndoIsReported() async throws {
        defer { try? FileManager.default.removeItem(at: mediaDirectory) }
        let recorder = MinedRecorder()
        var cancelled: [Int64] = []
        service.onCancelled = { cancelled.append($0) }
        let mined = try await service.mine(Self.hisshi, sentence: "必死だ", context: ReportingContext(recorder: recorder))
        #expect(recorder.mined == [mined])
        #expect(service.cancel(mined.jobId))
        #expect(cancelled == [mined.jobId])
    }

    @Test func missingMediaIsNotedOnTheCard() async throws {
        defer { try? FileManager.default.removeItem(at: mediaDirectory) }
        let mined = try await service.mine(Self.hisshi, sentence: "必死だ", context: FailedClipContext())
        let queued = try #require(try OutboxStore(database: database).job(mined.jobId))
        #expect(queued.media.isEmpty)
        #expect(try queued.job.decodePayload(MinedCard.self).mediaProblems == ["No picture: The clip came out empty."])
        let plain = try await service.mine(Self.hisshi, sentence: "必死だ", context: StubContext(picture: nil, miscInfo: ""), allowDuplicate: true)
        #expect(try #require(try OutboxStore(database: database).job(plain.jobId)).job.decodePayload(MinedCard.self).mediaProblems == nil)
    }

    @Test func mineQueuesCardWithPictureAfterUndoWindow() async throws {
        defer { try? FileManager.default.removeItem(at: mediaDirectory) }
        let mined = try await service.mine(Self.hisshi, sentence: "必死だ", context: StubContext(picture: Self.png(width: 2000, height: 3000), miscInfo: "Src"))
        #expect(service.isMined(Self.hisshi))

        let queued = try #require(try OutboxStore(database: database).job(mined.jobId))
        #expect(queued.job.kind == .ankiNote)
        #expect(queued.job.nextAttemptAt > Date().addingTimeInterval(3))
        #expect(try queued.job.decodePayload(MinedCard.self).content[.miscInfo] == "Src")
        let picture = try #require(queued.media.first)
        #expect(picture.field == MinedCard.pictureMedia && picture.filename.hasSuffix(".jpg"))

        let file = mediaDirectory.appending(path: picture.filename)
        let source = try #require(CGImageSourceCreateWithURL(file as CFURL, nil))
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        #expect(properties?[kCGImagePropertyPixelHeight] as? Int == 1600, "downscaled to the longest side")
        #expect(CGImageSourceGetType(source) as String? == UTType.jpeg.identifier)
    }

    @Test func animatedPicturesAreKeptAsTheyAre() async throws {
        defer { try? FileManager.default.removeItem(at: mediaDirectory) }
        let gif = Data("GIF89a-not-really".utf8)
        let mined = try await service.mine(Self.hisshi, sentence: "必死だ", context: AnimatedClipContext(gif: gif))
        let picture = try #require(try OutboxStore(database: database).job(mined.jobId)?.media.first)
        #expect(picture.field == MinedCard.pictureMedia && picture.filename.hasSuffix(".gif"))
        #expect(try Data(contentsOf: mediaDirectory.appending(path: picture.filename)) == gif)
    }

    @Test func cancelRemovesCardMediaAndMark() async throws {
        defer { try? FileManager.default.removeItem(at: mediaDirectory) }
        let mined = try await service.mine(Self.hisshi, sentence: nil, context: StubContext(picture: Self.png(width: 10, height: 10), miscInfo: ""))
        let filename = try #require(try OutboxStore(database: database).job(mined.jobId)?.media.first?.filename)
        #expect(service.cancel(mined.jobId))
        #expect(!service.isMined(Self.hisshi))
        #expect(!FileManager.default.fileExists(atPath: mediaDirectory.appending(path: filename).path()))
        #expect(try OutboxStore(database: database).summary() == .empty)
    }

    @Test func searchCardsHaveNoPictureOrSource() async throws {
        let mined = try await service.mine(Self.hisshi, sentence: nil, context: nil)
        let queued = try #require(try OutboxStore(database: database).job(mined.jobId))
        #expect(queued.media.isEmpty)
        let card = try queued.job.decodePayload(MinedCard.self)
        #expect(card.content[.sentence] == nil && card.content[.miscInfo] == nil)
    }

    @Test func entriesShowTheMineButtonOnlyWhenMiningIsOn() {
        #expect(!EntryRenderer.entries([Self.hisshi]).contains("mine-button"))
        #expect(EntryRenderer.entries([Self.hisshi], mined: [false]).contains("class=\"mine-button\" data-action=\"mine\" data-index=\"0\""))
        #expect(EntryRenderer.entries([Self.hisshi], mined: [true]).contains("class=\"mine-button mined\""))
    }

    @Test func nestedLookupsUseTheFirstPagesSentence() {
        let model = LookupPopupModel(page: LookupResultPage(query: "必死", sentence: "必死だった。", results: [Self.hisshi]))
        let nested = LookupResultPage(query: "frantic", sentence: "desperate, frantic", results: [])
        model.push(nested)
        #expect(model.sentence(for: Self.hisshi, on: nested) == "必死だった。")
    }
}
