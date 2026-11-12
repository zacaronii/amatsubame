import Core
import CoreTestSupport
import CryptoKit
import Dictionary
import DictionaryTestSupport
import Foundation
@testable import Lookup
import Testing

@Suite struct AudioSourceTests {
    @Test func templateExpansionEncodesTermAndReading() {
        let url = AudioService.expand("http://audio.local:5050/?term={term}&reading={reading}", term: "食べる", reading: "たべる")
        #expect(url?.absoluteString == "http://audio.local:5050/?term=%E9%A3%9F%E3%81%B9%E3%82%8B&reading=%E3%81%9F%E3%81%B9%E3%82%8B")
        #expect(AudioService.expand("http://a/{term}/{reading}", term: "a&b", reading: "")?.absoluteString == "http://a/a%26b/a%26b")
    }

    @Test func jpod101MatchesYomitansParameters() {
        #expect(AudioService.jpod101URL(term: "食べる", reading: "たべる").query == "kanji=%E9%A3%9F%E3%81%B9%E3%82%8B&kana=%E3%81%9F%E3%81%B9%E3%82%8B")
        #expect(AudioService.jpod101URL(term: "たべる", reading: "たべる").query == "kana=%E3%81%9F%E3%81%B9%E3%82%8B")
    }

    @Test func audioListParsesYomitanJSONWithRelativeURLs() {
        let json = Data(#"{"type":"audioSourceList","audioSources":[{"name":"NHK","url":"/media/a.mp3"},{"url":"https://x.example/b.mp3"}]}"#.utf8)
        let urls = AudioService.parseAudioList(json, base: URL(string: "http://audio.local:5050/?term=x")!)
        #expect(urls.map(\.absoluteString) == ["http://audio.local:5050/media/a.mp3", "https://x.example/b.mp3"])
        #expect(AudioService.parseAudioList(Data("{}".utf8), base: URL(string: "http://a")!).isEmpty)
    }

    @Test func jpod101NotAvailableClipIsRejected() {
        let clip = Data("not really mp3".utf8)
        #expect(AudioService.isValidAudio(clip, contentType: "audio/mpeg", kind: .jpod101))
        #expect(!AudioService.isValidAudio(Data(), contentType: "audio/mpeg", kind: .url))
        #expect(!AudioService.isValidAudio(clip, contentType: "text/html; charset=UTF-8", kind: .url))
        #expect(!AudioService.isValidAudio(clip, contentType: "application/json", kind: .json))
        #expect(AudioService.jpod101Missing.count == 64)
    }

    @Test @MainActor func defaultSourcesInstallOnce() throws {
        let audio = AudioService(database: try AppDatabase.inMemory())
        try audio.installDefaultSourcesIfNeeded()
        try audio.installDefaultSourcesIfNeeded()
        #expect(try audio.sources().map(\.kind) == [.jpod101])
    }

    /// Edits go to the service's own database (the shared setup's when an app shares it).
    @Test @MainActor func sourcesAreSavedReorderedAndDeleted() throws {
        let audio = AudioService(database: try AppDatabase.inMemory())
        try audio.installDefaultSourcesIfNeeded()
        try audio.save(AudioSourceRecord(kind: .url, name: "Local", template: "http://audio.local/{term}", sortOrder: 1))
        try audio.reorder(try audio.sources().reversed())
        #expect(try audio.sources().map(\.name) == ["Local", "JapanesePod101"])
        try audio.delete(ids: [try #require(try audio.sources().first?.id)])
        #expect(try audio.sources().map(\.name) == ["JapanesePod101"])
    }

    @Test @MainActor func jsonSourceListsCandidates() async throws {
        let transport = StubTransport(routes: ["/list": (200, Data(#"{"type":"audioSourceList","audioSources":[{"url":"/a.mp3"}]}"#.utf8))])
        let audio = AudioService(database: try AppDatabase.inMemory(), http: HTTPClient(transport: transport))
        let source = AudioSourceRecord(kind: .json, name: "Local", template: "http://audio.local/list?term={term}")
        let urls = await audio.candidates(source, term: "食べる", reading: "たべる")
        #expect(urls.map(\.absoluteString) == ["http://audio.local/a.mp3"])
    }

    @Test func keysAreMaskedAndSplitOut() {
        let template = "https://audio.example.com/?term={term}&reading={reading}&apiKey=abc123"
        #expect(AudioSourceKeys.masked(template) == "https://audio.example.com/?term={term}&reading={reading}&apiKey=••••")
        #expect(AudioSourceKeys.hasSecret(template))
        #expect(!AudioSourceKeys.hasSecret("http://host:5050/?term={term}&reading={reading}"))
        #expect(AudioSourceKeys.masked("https://x.test/a?api_key=1&token=2") == "https://x.test/a?api_key=••••&token=••••")
        let split = AudioSourceKeys.split(template) { "k1" }
        #expect(split.template == "https://audio.example.com/?term={term}&reading={reading}&apiKey={key:k1}")
        #expect(split.keys == ["k1": "abc123"])
        #expect(AudioSourceKeys.masked(split.template) == AudioSourceKeys.masked(template))
        #expect(AudioSourceKeys.split(split.template).keys.isEmpty)
        #expect(AudioSourceKeys.filled(split.template, keys: split.keys) == template)
    }

    /// Keys go to the secret store; the database only has placeholders, and lookups still use the key.
    @Test @MainActor func keysAreKeptInTheSecretStore() async throws {
        let database = try AppDatabase.inMemory()
        let secrets = InMemorySecretStore()
        let audio = AudioService(database: database, secrets: secrets)
        // Saved before keys went to the Keychain: moved at the next launch.
        let old = AudioSourceRecord(kind: .url, name: "Ultimate", template: "https://audio.test/{term}.mp3?apiKey=abc123")
        try await database.writer.write { db in
            var saved = old
            try saved.save(db)
        }
        try audio.moveKeysToKeychain()
        let source = try #require(try audio.sources().first)
        #expect(!source.template.contains("abc123"))
        #expect(try #require(try secrets.secret(for: .audioSourceKeys)).contains("abc123"))
        #expect(audio.editableTemplate(source) == old.template)
        let urls = await audio.candidates(source, term: "猫", reading: "ねこ")
        #expect(urls.first?.absoluteString.hasSuffix("apiKey=abc123") == true)
        // Deleting the source forgets its key.
        try audio.delete(ids: [try #require(source.id)])
        #expect(try secrets.secret(for: .audioSourceKeys) == nil)
    }
}

@Suite @MainActor struct LookupServiceTests {
    func makeService() async throws -> LookupService {
        let database = try AppDatabase.inMemory()
        let library = DictionaryLibrary(database: database, directory: FileManager.default.temporaryDirectory.appending(path: "lookup-\(UUID().uuidString)"))
        var builder = TestDictionaryBuilder(title: "Terms")
        builder.terms = [
            .init("食べる", "たべる", rules: "v1", glossary: ["to eat"]),
            .init("映画", "えいが", glossary: ["movie"]),
        ]
        builder.styles = "span { color: red; }"
        try await library.importDictionary(at: try builder.write())
        let service = LookupService(library: library, audio: AudioService(database: database))
        try await service.reload()
        return service
    }

    @Test func tapLooksUpFromTheTappedCharacterAndKeepsTheSentence() async throws {
        let service = try await makeService()
        let text = "昨日、映画を見た。そして寿司を食べさせられなかった。"
        let page = await service.lookup(text: text, utf16Offset: 15)
        #expect(page.results.first?.expression == "食べる")
        #expect(page.query == "食べさせられなかった")
        #expect(page.sentence == "そして寿司を食べさせられなかった。")
        #expect(service.styles["Terms"] == "span { color: red; }")
    }

    @Test func lookupsWithResultsAreCountedForStats() async throws {
        let service = try await makeService()
        let log = ActivityLog(database: try AppDatabase.inMemory())
        service.activity = log
        _ = await service.lookup(text: "映画", utf16Offset: 0)
        _ = await service.lookup(text: "xyz", utf16Offset: 0)
        _ = await service.search("映画")
        #expect(try log.lookupDates().count == 1, "taps that found something; not searches")
    }

    @Test func historyRecordsMostRecentFirstWithoutDuplicates() async throws {
        let service = try await makeService()
        _ = await service.lookup(text: "映画", utf16Offset: 0)
        _ = await service.lookup(text: "食べた", utf16Offset: 0)
        _ = await service.lookup(text: "映画", utf16Offset: 0)
        var iterator = service.observeHistory().makeAsyncIterator()
        let history = try #require(try await iterator.next())
        #expect(history.map(\.expression) == ["映画", "食べる"])
        service.clearHistory()
        #expect(try await iterator.next()?.isEmpty == true)
    }

    @Test func searchFindsTypedText() async throws {
        let service = try await makeService()
        #expect(await service.search(" 食べた ").results.first?.expression == "食べる")
        #expect(await service.search("").results.isEmpty)
    }

    @Test func popupStackPushesAndGoesBack() {
        let model = LookupPopupModel()
        model.show(LookupResultPage(query: "a", results: []))
        model.push(LookupResultPage(query: "b", results: []))
        #expect(model.canGoBack)
        #expect(model.current?.query == "b")
        model.back()
        #expect(model.current?.query == "a")
        #expect(!model.canGoBack)
    }
}
