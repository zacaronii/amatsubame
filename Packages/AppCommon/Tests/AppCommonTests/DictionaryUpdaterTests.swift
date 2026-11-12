@testable import AppCommon
import Core
import CoreTestSupport
import Dictionary
import DictionaryTestSupport
import Foundation
import Lookup
import Testing

/// Serves canned responses by URL (the test's own session only).
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responses: [String: Data] = [:]
    nonisolated(unsafe) static var requests: [String] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!.absoluteString
        Self.requests.append(url)
        let data = Self.responses[url]
        let response = HTTPURLResponse(url: request.url!, statusCode: data == nil ? 404 : 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let data { client?.urlProtocol(self, didLoad: data) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    static var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

@MainActor @Suite(.serialized) struct DictionaryUpdaterTests {
    let index = "https://example.com/freq/index.json"
    let zipURL = "https://example.com/freq/dict.zip"

    func library() -> DictionaryLibrary {
        DictionaryLibrary(database: try! AppDatabase.inMemory(),
                          directory: FileManager.default.temporaryDirectory.appending(path: "updater-\(UUID().uuidString)"))
    }

    func updater(_ library: DictionaryLibrary) -> DictionaryUpdater {
        DictionaryUpdater(library: library, lookup: LookupService(library: library, audio: AudioService(database: library.database, http: HTTPClient(), secrets: InMemorySecretStore())), reachability: Reachability(),
                          session: StubURLProtocol.session)
    }

    func terms(_ title: String, revision: String = "1") throws -> URL {
        var builder = TestDictionaryBuilder(title: title, revision: revision)
        builder.terms = [.init("食べる", "たべる")]
        return try builder.write()
    }

    func frequency(_ title: String, revision: String) throws -> Data {
        var builder = TestDictionaryBuilder(title: title, revision: revision)
        builder.frequencies = [("食べる", nil, 10, nil)]
        builder.index = ["isUpdatable": true, "indexUrl": index, "downloadUrl": zipURL]
        return try builder.zipData()
    }

    func serve(revision: String, zip: Data) {
        StubURLProtocol.requests = []
        StubURLProtocol.responses = [
            index: Data(#"{"title": "Freq", "revision": "\#(revision)", "isUpdatable": true, "indexUrl": "\#(index)", "downloadUrl": "\#(zipURL)"}"#.utf8),
            zipURL: zip,
        ]
    }

    @Test func aNewerRevisionReplacesTheDictionaryInPlace() async throws {
        let library = library()
        let old = try await library.importDictionary(at: try terms("Freq [1]", revision: "1"),
                                                     catalogId: "jiten").dictionary
        // Installed from the set, but its own index has the update address.
        try await library.saveSource(DictionarySource(dictionaryId: old.id, catalogId: "jiten", indexUrl: index, isUpdatable: true))
        let updater = updater(library)
        serve(revision: "2", zip: try frequency("Freq [2]", revision: "2"))
        await updater.checkForUpdates()
        let now = try #require(try library.dictionaries().first)
        #expect(now.id == old.id && now.title == "Freq [2]" && now.revision == "2")
        #expect(updater.lastResult == "Updated Freq [2].")

        // Nothing newer: only the index is fetched.
        StubURLProtocol.requests = []
        await updater.checkForUpdates()
        #expect(StubURLProtocol.requests == [index])
        #expect(updater.lastResult == "Everything is up to date.")
    }

    @Test func aDownloadStillOnTheOldRevisionIsntTriedAgain() async throws {
        let library = library()
        let old = try await library.importDictionary(at: try terms("Freq", revision: "1")).dictionary
        try await library.saveSource(DictionarySource(dictionaryId: old.id, indexUrl: index, isUpdatable: true))
        let updater = updater(library)
        // The index says 2, but the zip is still 1 (a stale mirror).
        serve(revision: "2", zip: try frequency("Freq", revision: "1"))
        await updater.checkForUpdates()
        #expect(try library.sources()[old.id]?.undeliveredRevision == "2")
        StubURLProtocol.requests = []
        await updater.checkForUpdates()
        #expect(StubURLProtocol.requests == [index], "no second download of the same old zip")
        #expect(try library.dictionaries().first?.revision == "1")
    }

    /// A zip with only its index, like a broken release.
    func empty(_ title: String, revision: String) throws -> Data {
        try TestDictionaryBuilder(title: title, revision: revision).zipData()
    }

    @Test func anEmptyUpdateKeepsTheWorkingDictionary() async throws {
        let library = library()
        let old = try await library.importDictionary(at: try terms("Freq", revision: "1")).dictionary
        try await library.saveSource(DictionarySource(dictionaryId: old.id, indexUrl: index, isUpdatable: true))
        let updater = updater(library)
        serve(revision: "2", zip: try empty("Freq", revision: "2"))
        await updater.checkForUpdates()
        let now = try #require(try library.dictionaries().first)
        #expect(now.revision == "1" && now.termCount == 1, "the working dictionary stays")
        #expect(try library.sources()[old.id]?.undeliveredRevision == "2")
        StubURLProtocol.requests = []
        await updater.checkForUpdates()
        #expect(StubURLProtocol.requests == [index], "the empty release isn't downloaded again")
    }

    @Test func anEmptyLatestReleaseFallsBackToThePreviousOne() async throws {
        let library = library()
        let updater = updater(library)
        let entry = try #require(RecommendedDictionaries.entry("jmnedict"))
        let previous = "https://github.com/yomidevs/jmdict-yomitan/releases/download/2026-11-05/JMnedict.zip"
        let releases = """
        [{"draft": false, "prerelease": false, "assets": [{"name": "JMnedict.zip", "browser_download_url": "https://github.com/yomidevs/jmdict-yomitan/releases/download/2026-11-12/JMnedict.zip"}]},
         {"draft": false, "prerelease": false, "assets": [{"name": "KANJIDIC_english.zip", "browser_download_url": "https://example.com/k.zip"},
                                                         {"name": "JMnedict.zip", "browser_download_url": "\(previous)"}]}]
        """
        var names = TestDictionaryBuilder(title: "JMnedict [2026-11-05]", revision: "2026-11-05")
        names.terms = [.init("東京", "とうきょう")]
        StubURLProtocol.requests = []
        StubURLProtocol.responses = [
            entry.downloadURL.absoluteString: try empty("JMnedict [2026-11-12]", revision: "2026-11-12"),
            "https://api.github.com/repos/yomidevs/jmdict-yomitan/releases?per_page=6": Data(releases.utf8),
            previous: try names.zipData(),
        ]
        await updater.installRecommended(["jmnedict"])
        #expect(updater.items["jmnedict"] == .installed)
        #expect(try library.dictionaries().map(\.title) == ["JMnedict [2026-11-05]"])
        #expect(updater.installedRecommended() == ["jmnedict"])
    }

    @Test func onlyGitHubLatestAddressesHaveEarlierReleases() async {
        let updater = updater(library())
        StubURLProtocol.requests = []
        #expect(await updater.earlierReleases(of: URL(string: "https://api.jiten.moe/api/frequency-list/download")!).isEmpty)
        #expect(StubURLProtocol.requests.isEmpty)
    }

    @Test func importedDictionariesThatDontUpdateAreLeftAlone() async throws {
        let library = library()
        _ = try await library.importDictionary(at: try terms("Mine", revision: "1"))
        let updater = updater(library)
        await updater.adoptInstalled()
        StubURLProtocol.requests = []
        await updater.checkForUpdates()
        #expect(StubURLProtocol.requests.isEmpty)
        #expect(updater.selfUpdating().isEmpty)
    }

    @Test func installedDictionariesAreMatchedToTheSetByName() async throws {
        let library = library()
        _ = try await library.importDictionary(at: try terms("Jitendex.org [2026-10-03]"))
        _ = try await library.importDictionary(at: try terms("Jiten (Anime)"))
        let updater = updater(library)
        await updater.adoptInstalled()
        #expect(updater.installedRecommended() == ["jitendex"], "Jiten (Anime) isn't the global list")
    }

    @Test func theRecommendedSetInstallsAndSetsTheFrequencySort() async throws {
        let library = library()
        let updater = updater(library)
        let jiten = try #require(RecommendedDictionaries.entry("jiten"))
        StubURLProtocol.responses = [jiten.downloadURL.absoluteString: try frequency("Jiten", revision: "Jiten 26-11-01")]
        await updater.installRecommended(["jiten"])
        #expect(updater.items["jiten"] == .installed)
        #expect(try library.settings().frequencySortTitle == "Jiten")
        #expect(updater.installedRecommended() == ["jiten"])
        let id = try #require(try library.dictionaries().first?.id)
        try await library.delete(id)
        #expect(updater.removedRecommended() == ["jiten"])
    }
}
