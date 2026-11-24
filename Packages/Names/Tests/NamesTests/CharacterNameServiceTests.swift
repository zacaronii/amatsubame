import Core
import CoreTestSupport
import Dictionary
import DictionaryTestSupport
import Foundation
@testable import Names
import Testing

/// The names dictionary from end to end with a made-up cast: AniList and MangaBaka stubbed, the
/// dictionary installed into a real library and looked up.
@Suite struct CharacterNameServiceTests {
    let folder = FileManager.default.temporaryDirectory.appending(path: "names-\(UUID().uuidString)")

    func makeService(_ transport: StubTransport, database: AppDatabase? = nil) throws -> (CharacterNameService, DictionaryLibrary, AppDatabase) {
        let database = try database ?? AppDatabase.inMemory()
        let library = DictionaryLibrary(database: database, directory: folder.appending(path: "Dictionaries"))
        let http = HTTPClient(transport: transport)
        let noWait = RequestLimiter(spacing: .zero)
        let service = CharacterNameService(
            database: database, library: library, aniList: AniListClient(http: http, limiter: noWait),
            mangaBaka: MangaBakaClient(http: http, limiter: noWait),
            portraits: PortraitStore(directory: folder.appending(path: "Portraits"), http: http),
            readings: FakeReadings(), scratch: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return (service, library, database)
    }

    func series(_ id: Int = 1, aniList: Int? = nil, mal: Int? = nil, title: String = "架空の物語", kind: MangaBakaClient.Kind? = .manga) -> NamedSeries {
        NamedSeries(key: "kavita:test:\(id)", title: title, type: .manga, kind: kind, aniListId: aniList, malId: mal)
    }

    @Test func openingPutsTheCastInTheDictionary() async throws {
        let transport = try NamesFixtures.transport()
        let (service, library, _) = try makeService(transport)
        // A word dictionary and JMnedict installed already: the names go between them.
        try await library.importDictionary(at: TestDictionaryBuilder(title: "Jitendex").adding("太郎", "たろう").write(to: folder))
        try await library.importDictionary(at: TestDictionaryBuilder(title: "JMnedict").adding("夢見", "ゆめみ").write(to: folder))

        #expect(await service.open(series(aniList: 900001), app: "yomu") == .ready(characters: 6))
        #expect(try library.dictionaries().map(\.title) == ["Jitendex", "Character Names", "JMnedict"])

        let found = await library.engine.lookup("架空太郎は")
        let name = try #require(found.first { $0.glossaries.contains { $0.dictionary == "Character Names" } })
        #expect(name.expression == "架空太郎" && name.reading == "かくうたろう" && name.matched == "架空太郎")
        let card = try #require(name.glossaries.first?.json)
        #expect(card.contains("Tarou Kakuu") && card.contains("Main character in 架空の物語") && card.contains("img/1001.jpg"))
        // The portrait is in the dictionary, small.
        let record = try #require(try library.dictionaries().first { $0.title == "Character Names" })
        let image = try #require(await library.engine.mediaFile(dictionary: record.title, path: "img/1001.jpg"))
        #expect(image.count > 100 && image.count < 20_000)
        // Background characters and descriptions aren't names.
        #expect(await library.engine.lookup("通行人").allSatisfy { !$0.glossaries.contains { $0.dictionary == "Character Names" } })
    }

    /// A name in kana alone (one word, with ー) and one mixing kanji and kana are found as
    /// written, read as their own kana.
    @Test func kanaNamesAreFound() async throws {
        let (service, library, _) = try makeService(try NamesFixtures.transport())
        _ = await service.open(series(aniList: 900001), app: "yomu")
        for (text, expression, reading) in [("エルリーネは", "エルリーネ", "えるりーね"), ("灰原ユーリが", "灰原ユーリ", "はいばらゆーり"), ("ユーリ", "ユーリ", "ゆーり")] {
            let found = await library.engine.lookup(text)
            let name = found.first { $0.glossaries.contains { $0.dictionary == "Character Names" } }
            #expect(name?.expression == expression && name?.reading == reading, "\(text): \(found.map { "\($0.expression)/\($0.reading)" })")
        }
    }

    /// Kept for 30 days: opening the series again asks AniList nothing.
    @Test func castsAreKept() async throws {
        let transport = try NamesFixtures.transport()
        let (service, _, _) = try makeService(transport)
        _ = await service.open(series(aniList: 900001), app: "yomu")
        let asked = transport.requests.filter { $0.url?.host() == "graphql.anilist.co" }.count
        await service.close(app: "yomu")
        #expect(await service.open(series(aniList: 900001), app: "yomu") == .ready(characters: 6))
        #expect(transport.requests.filter { $0.url?.host() == "graphql.anilist.co" }.count == asked)
    }

    /// Closing takes the cast out; with nothing open the dictionary goes.
    @Test func closingRemovesTheDictionary() async throws {
        let (service, library, _) = try makeService(try NamesFixtures.transport())
        _ = await service.open(series(aniList: 900001), app: "yomu")
        _ = await service.open(series(2, aniList: 900001), app: "miru")
        await service.close(app: "yomu")
        #expect(try library.dictionaries().map(\.title) == ["Character Names"])
        await service.close(app: "miru")
        #expect(try library.dictionaries().isEmpty)
    }

    @Test func malIdAndMangaBakaFindTheSeries() async throws {
        let (service, _, database) = try makeService(try NamesFixtures.transport())
        #expect(await service.open(series(1, mal: 800001), app: "yomu") == .ready(characters: 6))
        #expect(await service.open(series(2), app: "yomu") == .ready(characters: 6))
        let matches = try await database.reader.read { try CharacterNameMatch.fetchAll($0) }
        #expect(matches.map(\.source) == [.linked, .linked] && matches.allSatisfy { $0.mediaKey == "MANGA:900001" })
    }

    /// No ids and MangaBaka unsure: AniList's search, kept only when exactly one result is the
    /// same title in the right format (a light novel's NOVEL, a manga's not).
    @Test func searchTakesOnlyAStrictMatch() async throws {
        let none = try NamesFixtures.transport(mangaBaka: Data(#"{"status":200,"data":[]}"#.utf8))
        let (service, _, database) = try makeService(none)
        #expect(await service.open(series(1, kind: .manga), app: "yomu") == .ready(characters: 6))
        #expect(await service.open(series(2, kind: .novel), app: "yomu") == .ready(characters: 6))
        let matches = try await database.reader.read { try CharacterNameMatch.fetchAll($0) }.sorted { $0.seriesKey < $1.seriesKey }
        #expect(matches.map(\.mediaKey) == ["MANGA:900001", "MANGA:900002"] && matches.allSatisfy { $0.source == .search })
        // A title that's only part of another's (外伝) isn't a match.
        #expect(await service.open(series(3, title: "外伝", kind: .manga), app: "yomu") == .needsPick)
    }

    @Test func pickingAndSayingNone() async throws {
        let (service, library, _) = try makeService(try NamesFixtures.transport())
        let unknown = series(4, title: "知らない題名", kind: nil)
        #expect(await service.open(unknown, app: "yomu") == .needsPick)
        #expect(try library.dictionaries().isEmpty)
        let candidates = try await service.candidates("架空", type: .manga)
        try await service.pick(candidates.first, for: unknown)
        #expect(try library.dictionaries().map(\.title) == ["Character Names"])
        try await service.pick(nil, for: unknown)
        #expect(try library.dictionaries().isEmpty)
        #expect(await service.open(unknown, app: "yomu") == .none)
    }

    /// Killed with a book open (the reader never closed): the next launch takes its cast out.
    @Test func aSeriesLeftOpenGoesAtTheNextLaunch() async throws {
        let transport = try NamesFixtures.transport()
        let (service, library, database) = try makeService(transport)
        _ = await service.open(series(aniList: 900001), app: "yomu")
        #expect(try library.dictionaries().map(\.title) == ["Character Names"])
        // A new process: the same setup, a new service (a moment later).
        try await Task.sleep(for: .milliseconds(20))
        let (relaunched, _, _) = try makeService(transport, database: database)
        await relaunched.launched(app: "yomu")
        #expect(try await database.reader.read { try CharacterNameOpenSeries.fetchCount($0) } == 0)
        #expect(try DictionaryLibrary(database: database, directory: folder.appending(path: "Dictionaries")).dictionaries().isEmpty)
        _ = library
    }

    /// A search that couldn't settle the series isn't run again on every open, only after a day.
    @Test func anUnsettledSeriesIsSearchedAgainAfterADay() async throws {
        let transport = try NamesFixtures.transport()
        let clock = TestClock()
        let database = try AppDatabase.inMemory()
        let library = DictionaryLibrary(database: database, directory: folder.appending(path: "Dictionaries"))
        let http = HTTPClient(transport: transport)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let service = CharacterNameService(
            database: database, library: library, aniList: AniListClient(http: http, limiter: RequestLimiter(spacing: .zero)),
            mangaBaka: MangaBakaClient(http: http, limiter: RequestLimiter(spacing: .zero)),
            portraits: PortraitStore(directory: folder.appending(path: "Portraits"), http: http), readings: FakeReadings(),
            scratch: folder, now: { clock.now })
        let unknown = series(4, title: "知らない題名", kind: nil)
        func searches() -> Int { transport.requests.filter { $0.url?.host() == "graphql.anilist.co" }.count }
        #expect(await service.open(unknown, app: "yomu") == .needsPick)
        let asked = searches()
        #expect(await service.open(unknown, app: "yomu") == .needsPick)
        #expect(searches() == asked, "not searched again the same day")
        clock.now += CharacterNameService.searchRetry + 1
        #expect(await service.open(unknown, app: "yomu") == .needsPick)
        #expect(searches() > asked, "searched again a day later")
    }

    @Test func turningItOff() async throws {
        let (service, library, _) = try makeService(try NamesFixtures.transport())
        _ = await service.open(series(aniList: 900001), app: "yomu")
        try await service.setEnabled(false)
        #expect(try library.dictionaries().isEmpty)
        #expect(await service.open(series(aniList: 900001), app: "yomu") == .none)
        try await service.setEnabled(true)
        #expect(try library.dictionaries().map(\.title) == ["Character Names"])
    }

    /// A 429 is waited out (AniList's Retry-After) and the request sent again.
    @Test func rateLimitWaitsAndRetries() async throws {
        let cast = try NamesFixtures.data("anilist-cast.json")
        let calls = Counter()
        let transport = StubTransport { _ in calls.increment() == 1 ? (429, Data()) : (200, cast) }
        let waits = Recorder()
        let limiter = RequestLimiter(spacing: .zero) { waits.add($0) }
        let client = AniListClient(http: HTTPClient(transport: transport), limiter: limiter)
        let (_, characters) = try await client.cast(mediaId: 900001, type: .manga)
        #expect(characters.count == 6 && calls.value == 2)
        #expect(waits.values.contains { $0 >= .seconds(59) }, "no Retry-After header: a minute, as AniList's timeout")
    }
}

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var value = 0
    func increment() -> Int { lock.withLock { value += 1; return value } }
}

final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Duration] = []
    func add(_ duration: Duration) { lock.withLock { recorded.append(duration) } }
    var values: [Duration] { lock.withLock { recorded } }
}

extension TestDictionaryBuilder {
    func adding(_ expression: String, _ reading: String) -> TestDictionaryBuilder {
        var copy = self
        copy.terms.append(Term(expression, reading))
        return copy
    }
}
