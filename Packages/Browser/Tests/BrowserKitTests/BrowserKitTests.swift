import AppCommon
import BrowserKit
import Core
import CoreTestSupport
import Dictionary
import DictionaryTestSupport
import Foundation
import Lookup
import Testing

@Suite struct BrowserRequestTests {
    @Test func messages() {
        #expect(BrowserRequest(["action": "lookup", "text": "映画を見た", "offset": 2, "title": "NHK", "url": "https://nhk.or.jp"])
            == .lookup(text: "映画を見た", offset: 2, title: "NHK", url: "https://nhk.or.jp"))
        // JavaScript numbers can come through as doubles.
        #expect(BrowserRequest(["action": "lookup", "text": "映画", "offset": 1.0]) == .lookup(text: "映画", offset: 1, title: nil, url: nil))
        #expect(BrowserRequest(["action": "mine", "id": "A", "index": 0]) == .mine(id: "A", index: 0))
        #expect(BrowserRequest(["action": "audio", "id": "A", "index": 1.0]) == .audio(id: "A", index: 1))
        #expect(BrowserRequest(["action": "query", "query": "見る"]) == .query("見る"))
        #expect(BrowserRequest(["action": "saveAnki", "url": "anki.local:8765"]) == .saveAnki(url: "anki.local:8765", apiKey: "", deck: ""))
        #expect(BrowserRequest(["action": "undo", "jobId": 7]) == .undo(jobId: 7))
        #expect(BrowserRequest(["action": "send", "jobId": 7]) == .send(jobId: 7))
        #expect(BrowserRequest(["action": "status"]) == .status)
    }

    @Test func badMessagesAreRejected() {
        #expect(BrowserRequest(nil) == nil)
        #expect(BrowserRequest(["action": "lookup", "text": "映画", "offset": 5]) == nil)
        #expect(BrowserRequest(["action": "lookup", "text": "映画", "offset": 0.5]) == nil)
        #expect(BrowserRequest(["action": "mine", "id": "A", "index": -1]) == nil)
        #expect(BrowserRequest(["action": "delete-everything"]) == nil)
    }
}

@Suite struct BrowserStorageTests {
    let own = URL(filePath: "/tmp/own-support")

    @Test func withoutTheAppGroupEachProcessUsesItsOwnFolder() {
        let location = BrowserStorage.location(containerURL: { _ in nil }, ownSupport: own)
        #expect(location == .init(root: own, isShared: false))
    }

    @Test func withTheAppGroupTheSharedFolderIsUsed() {
        let group = FileManager.default.temporaryDirectory.appending(path: "group-\(UUID().uuidString)")
        let location = BrowserStorage.location(containerURL: { $0 == BrowserStorage.groupIdentifier ? group : nil }, ownSupport: own)
        #expect(location.isShared)
        #expect(location.root.path().hasPrefix(group.path()))
    }
}

@Suite @MainActor struct BrowserServiceTests {
    /// A fake AnkiConnect: answers by action name (nil: the server is down).
    static func anki(_ answers: [String: String]?) -> StubTransport {
        StubTransport { request in
            guard let answers else { return (503, Data()) }
            let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any]
            let action = body?["action"] as? String ?? ""
            guard let result = answers[action] else { return (200, Data(#"{"result": null, "error": "unsupported"}"#.utf8)) }
            return (200, Data(#"{"result": \#(result), "error": null}"#.utf8))
        }
    }

    func makeService(dictionary: TestDictionaryBuilder, transport: StubTransport = anki(nil),
                     extraDictionaries: [URL] = []) throws -> BrowserService {
        let root = FileManager.default.temporaryDirectory.appending(path: "browser-\(UUID().uuidString)")
        let common = CommonEnvironment(database: try AppDatabase.onDisk(directory: root.appending(path: "Database")),
                                       secrets: InMemorySecretStore(), mediaDirectory: root.appending(path: "Media"),
                                       dictionaryDirectory: root.appending(path: "Dictionaries"),
                                       http: HTTPClient(transport: transport))
        return BrowserService(common: common, bundledDictionaries: [try dictionary.write()] + extraDictionaries,
                              defaults: UserDefaults(suiteName: "browser-\(UUID().uuidString)")!)
    }

    static var eat: TestDictionaryBuilder {
        var builder = TestDictionaryBuilder(title: "Terms")
        builder.terms = [.init("食べる", "たべる", rules: "v1", glossary: ["to eat"]), .init("見る", "みる", rules: "v1", glossary: ["to see"])]
        return builder
    }

    @Test func importsBundledDictionariesOnceAndAnswersLookups() async throws {
        let service = try makeService(dictionary: Self.eat)
        let response = await service.handle(["action": "lookup", "text": "寿司を食べさせられなかった。", "offset": 3])
        #expect(response["found"] as? Bool == true)
        #expect(response["matchLength"] as? Int == "食べさせられなかった".utf16.count)
        #expect((response["html"] as? String)?.contains("to eat") == true)
        #expect(response["id"] as? String != nil)
        #expect(((response["stats"] as? [String: Any])?["prepareMs"]) != nil)
        // Glossary links look a word up by itself.
        let query = await service.handle(["action": "query", "query": "見る"])
        #expect((query["html"] as? String)?.contains("to see") == true)
        let status = await service.handle(["action": "status"])
        #expect(status["dictionaries"] as? [String] == ["Terms"])
        #expect(status["anki"] == nil)
    }

    @Test func bilingualDictionariesComeFirst() {
        let names = ["[Pitch] アクセント辞典v2.zip", "[Freq] JPDB.zip", "[Bilingual] 新和英.zip", "[Grammar] 文法.zip",
                     "[Bilingual] JMdict (Recommended).zip", "[Kanji] KANJIDIC.zip"]
        let ordered = BrowserService.importOrder(names.map { URL(filePath: "/x/\($0)") }).map(\.lastPathComponent)
        #expect(ordered == ["[Bilingual] JMdict (Recommended).zip", "[Bilingual] 新和英.zip", "[Grammar] 文法.zip",
                            "[Freq] JPDB.zip", "[Kanji] KANJIDIC.zip", "[Pitch] アクセント辞典v2.zip"])
    }

    /// Built-in dictionaries as a build carries them: prebuilt packages (zips if `zip`).
    static func bundle(_ builders: [TestDictionaryBuilder], zip: Bool = false) throws -> [URL] {
        let folder = FileManager.default.temporaryDirectory.appending(path: "bundle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return try builders.map { builder in
            let source = try builder.write()
            if zip { return source }
            let package = folder.appending(path: "\(builder.title).hoshidict")
            try DictionaryLibrary.prebuild(zip: source, into: package)
            return package
        }
    }

    func service(root: URL, defaults: UserDefaults, bundled: [URL]) throws -> BrowserService {
        let common = CommonEnvironment(database: try AppDatabase.onDisk(directory: root.appending(path: "Database")),
                                       secrets: InMemorySecretStore(), mediaDirectory: root.appending(path: "Media"),
                                       dictionaryDirectory: root.appending(path: "Dictionaries"), http: HTTPClient(transport: Self.anki(nil)))
        return BrowserService(common: common, bundledDictionaries: bundled, defaults: defaults)
    }

    static func titled(_ title: String, _ word: String, _ gloss: String) -> TestDictionaryBuilder {
        var builder = TestDictionaryBuilder(title: title)
        builder.terms = [.init(word, "よみ", glossary: [gloss])]
        return builder
    }

    @Test func prebuiltDictionariesAreSetUpAndANewSetReplacesThem() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "browser-\(UUID().uuidString)")
        let defaults = UserDefaults(suiteName: "browser-\(UUID().uuidString)")!
        let first = try Self.bundle([Self.titled("A", "映画", "movie"), Self.titled("B", "見る", "to see")])
        let one = try service(root: root, defaults: defaults, bundled: first)
        let lookup = await one.handle(["action": "lookup", "text": "映画", "offset": 0])
        #expect((lookup["html"] as? String)?.contains("movie") == true)
        #expect(try one.library.dictionaries().map(\.title) == ["A", "B"])
        // A relaunch with the same set does nothing; a build with another set swaps.
        let again = try service(root: root, defaults: defaults, bundled: first)
        _ = await again.handle(["action": "status"])
        #expect(try again.library.dictionaries().map(\.title) == ["A", "B"])
        let swapped = try service(root: root, defaults: defaults, bundled: [first[1]] + (try Self.bundle([Self.titled("C", "食べる", "to eat")])))
        _ = await swapped.handle(["action": "status"])
        #expect(try swapped.library.dictionaries().map(\.title) == ["B", "C"])
    }

    /// iOS stopped the extension while setting up B: the next launch keeps A, retries B, and
    /// after B stops it twice, skips it so lookups work.
    @Test func setupResumesAndSkipsADictionaryThatKeepsFailing() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "browser-\(UUID().uuidString)")
        let defaults = UserDefaults(suiteName: "browser-\(UUID().uuidString)")!
        let items = try Self.bundle([Self.titled("A", "映画", "movie"), Self.titled("B", "見る", "to see")])
        let first = try service(root: root, defaults: defaults, bundled: [items[0]])
        _ = await first.handle(["action": "status"])
        // Killed while setting up B (twice): the marker is left behind.
        defaults.set(items[1].lastPathComponent, forKey: "bundledDictionaries.attempting")
        defaults.set([items[1].lastPathComponent: 1], forKey: "bundledDictionaries.failures")
        let next = try service(root: root, defaults: defaults, bundled: items)
        let status = await next.handle(["action": "status"])
        #expect(try next.library.dictionaries().map(\.title) == ["A"])
        #expect(status["skipped"] as? [String] == ["B"])
        #expect((await next.handle(["action": "lookup", "text": "映画", "offset": 0])["html"] as? String)?.contains("movie") == true)
    }

    @Test func zipsStillWork() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "browser-\(UUID().uuidString)")
        let service = try service(root: root, defaults: UserDefaults(suiteName: "browser-\(UUID().uuidString)")!,
                                  bundled: try Self.bundle([Self.titled("Z", "映画", "movie")], zip: true))
        _ = await service.handle(["action": "status"])
        #expect(try service.library.dictionaries().map(\.title) == ["Z"])
    }

    @Test func audioAndMiningNeedAnEarlierLookup() async throws {
        let service = try makeService(dictionary: Self.eat)
        #expect(await service.handle(["action": "audio", "id": "gone", "index": 0])["error"] != nil)
        #expect(await service.handle(["action": "mine", "id": "gone", "index": 0])["error"] as? String == "Look the word up again.")
    }

    @Test func miningAsksForAnkiFirstThenKeepsTheCardWhenTheServerIsDown() async throws {
        let service = try makeService(dictionary: Self.eat)
        let lookup = await service.handle(["action": "lookup", "text": "食べた", "offset": 0, "title": "記事", "url": "https://example.jp/a"])
        let id = try #require(lookup["id"] as? String)
        let before = await service.handle(["action": "mine", "id": id, "index": 0])
        #expect((before["error"] as? String)?.contains("AnkiConnect") == true)

        try service.common.accounts.save(ServerAccount(kind: .anki, baseURL: URL(string: "http://anki.local:8765")!))
        let mined = await service.handle(["action": "mine", "id": id, "index": 0])
        #expect(mined["mined"] as? Bool == true && mined["jobId"] != nil)
        let jobs = try service.common.outbox.jobs(states: [.pending, .failed, .inFlight])
        #expect(jobs.count == 1 && jobs[0].kind == .ankiNote)
        let card = String(decoding: jobs[0].payload, as: UTF8.self)
        #expect(card.contains("食べる") && card.contains("example.jp"))
        // Sending while the server is down keeps it queued.
        let jobId = try #require(mined["jobId"] as? Int64)
        #expect(await service.handle(["action": "send", "jobId": jobId])["sent"] as? Bool == false)
        #expect(try service.common.outbox.jobs(states: [.pending]).count == 1)
        // Undo takes it back.
        let undone = await service.handle(["action": "undo", "jobId": jobId])
        #expect(undone["undone"] as? Bool == true)
        #expect(try service.common.outbox.jobs(states: [.pending, .failed, .inFlight]).isEmpty)
    }

    @Test func ankiIsCheckedBeforeItsSaved() async throws {
        let down = try makeService(dictionary: Self.eat)
        #expect(await down.handle(["action": "saveAnki", "url": "anki.local:8765"])["error"] != nil)
        #expect(try down.common.accounts.account(.anki) == nil)

        let up = try makeService(dictionary: Self.eat, transport: Self.anki(["version": "6", "deckNames": #"["日本語::Mining", "Default"]"#]))
        let saved = await up.handle(["action": "saveAnki", "url": "anki.local:8765", "apiKey": "secret", "deck": "Default"])
        #expect(saved["ok"] as? Bool == true)
        #expect(saved["decks"] as? [String] == ["日本語::Mining", "Default"])
        #expect(try up.common.accounts.account(.anki)?.baseURL.absoluteString == "http://anki.local:8765")
        #expect(try up.common.secrets.secret(for: .ankiAPIKey) == "secret")
        #expect(try up.common.ankiSettings.settings().deck == "Default")
        let status = await up.handle(["action": "status"])
        #expect((status["anki"] as? [String: Any])?["deck"] as? String == "Default")
    }
}

@Suite @MainActor struct BrowserSharedSetupTests {
    /// The extension uses the shared setup's dictionaries (imported by another app) and
    /// notices when they change, without importing its built-in ones.
    @Test func usesTheSharedSetupAndReloadsWhenItChanges() async throws {
        let shared = SharedSetup(root: FileManager.default.temporaryDirectory.appending(path: "shared-\(UUID().uuidString)"))
        let sharedDatabase = try shared.openDatabase()
        // Another app imports into the shared setup.
        let readerLibrary = DictionaryLibrary(database: sharedDatabase, directory: shared.dictionaryDirectory)
        var movie = TestDictionaryBuilder(title: "Shared")
        movie.terms = [.init("映画", "えいが", glossary: ["movie"])]
        try await readerLibrary.importDictionary(at: try movie.write())

        let own = FileManager.default.temporaryDirectory.appending(path: "lookup-\(UUID().uuidString)")
        let defaults = UserDefaults(suiteName: "browser-\(UUID().uuidString)")!
        let common = CommonEnvironment(database: try AppDatabase.onDisk(directory: own.appending(path: "Database")),
                                       secrets: InMemorySecretStore(), mediaDirectory: own.appending(path: "Media"),
                                       dictionaryDirectory: own.appending(path: "Dictionaries"),
                                       sharedSetup: shared, sharedSecrets: InMemorySecretStore(),
                                       setupPreference: (defaults, BrowserStorage.setupPreferenceKey))
        #expect(common.setupMode == .shared)
        var bundled = TestDictionaryBuilder(title: "Bundled")
        bundled.terms = [.init("食べる", "たべる", rules: "v1", glossary: ["to eat"])]
        let service = BrowserService(common: common, bundledDictionaries: [try bundled.write()])

        let first = await service.handle(["action": "lookup", "text": "映画を見た", "offset": 0])
        #expect((first["html"] as? String)?.contains("movie") == true)
        #expect(try service.library.dictionaries().map(\.title) == ["Shared"])
        // AnkiConnect is set in the app then, not in the extension's menu.
        #expect(await service.handle(["action": "status"])["managedByApp"] as? Bool == true)
        #expect(await service.handle(["action": "saveAnki", "url": "anki.local"])["error"] != nil)

        // The other app adds a dictionary: the next lookup sees it.
        var more = TestDictionaryBuilder(title: "More")
        more.terms = [.init("見る", "みる", rules: "v1", glossary: ["to see"])]
        try await readerLibrary.importDictionary(at: try more.write())
        let second = await service.handle(["action": "lookup", "text": "見た", "offset": 0])
        #expect((second["html"] as? String)?.contains("to see") == true)
    }
}

/// Live: REAL_ANKI_URL (+ REAL_ANKI_KEY) and REAL_ANKI_DECK (a scratch deck; delete it after)
/// save AnkiConnect through the extension's menu message, then mine a made-up word.
@Suite @MainActor struct BrowserLiveAnkiTests {
    @Test func minesToARealDeck() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let url = environment["REAL_ANKI_URL"], let deck = environment["REAL_ANKI_DECK"] else { return }
        var builder = TestDictionaryBuilder(title: "Scratch")
        builder.terms = [.init("試験語", "しけんご", glossary: ["Hiku test word"])]
        let root = FileManager.default.temporaryDirectory.appending(path: "browser-live-\(UUID().uuidString)")
        let common = CommonEnvironment(database: try AppDatabase.onDisk(directory: root.appending(path: "Database")),
                                       secrets: InMemorySecretStore(), mediaDirectory: root.appending(path: "Media"),
                                       dictionaryDirectory: root.appending(path: "Dictionaries"))
        let service = BrowserService(common: common, bundledDictionaries: [try builder.write()])
        let saved = await service.handle(["action": "saveAnki", "url": url, "apiKey": environment["REAL_ANKI_KEY"] ?? "", "deck": deck])
        #expect(saved["ok"] as? Bool == true, "\(saved)")
        let lookup = await service.handle(["action": "lookup", "text": "これは試験語です。", "offset": 3,
                                           "title": "Browser test", "url": "https://example.jp/test"])
        let id = try #require(lookup["id"] as? String)
        let mined = await service.handle(["action": "mine", "id": id, "index": 0])
        #expect(mined["mined"] as? Bool == true, "\(mined)")
        try await Task.sleep(for: .seconds(MiningService.undoWindow + 0.5))
        let sent = await service.handle(["action": "send", "jobId": try #require(mined["jobId"] as? Int64)])
        #expect(sent["sent"] as? Bool == true, "\(sent["message"] ?? "")")
    }
}
