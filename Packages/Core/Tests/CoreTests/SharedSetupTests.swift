import Core
import Foundation
import GRDB
import Synchronization
import Testing

@Suite struct SharedSetupTests {
    func temporary(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appending(path: "\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    /// A setup with one dictionary (and its folder), Anki settings, an AnkiConnect account
    /// and a Kavita account (which isn't part of the setup).
    func setUp(_ database: AppDatabase, dictionaries: URL, title: String) throws {
        try database.writer.write { try DictionaryRecord(id: "id-\(title)", title: title, hasTerms: true).insert($0) }
        let folder = dictionaries.appending(path: "id-\(title)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(title.utf8).write(to: folder.appending(path: "index.bin"))
        try AccountStore(database: database).save(ServerAccount(kind: .anki, baseURL: URL(string: "http://anki-\(title).local")!))
        try AccountStore(database: database).save(ServerAccount(kind: .kavita, baseURL: URL(string: "http://kavita.local")!))
        var settings = AnkiSettings.default
        settings.deck = "Deck \(title)"
        try AnkiSettingsStore(database: database).save(settings)
    }

    @Test func copyingReplacesTheSetupButNotTheRest() throws {
        let sourceFolder = temporary("source"), destinationFolder = temporary("destination")
        let source = try AppDatabase.onDisk(directory: sourceFolder.appending(path: "db"))
        let destination = try AppDatabase.onDisk(directory: destinationFolder.appending(path: "db"))
        try setUp(source, dictionaries: sourceFolder.appending(path: "dicts"), title: "A")
        try setUp(destination, dictionaries: destinationFolder.appending(path: "dicts"), title: "B")
        try AccountStore(database: destination).save(ServerAccount(kind: .kavita, baseURL: URL(string: "http://mine.local")!))
        #expect(try !SharedSetup.isEmpty(destination))

        try SharedSetup.copy(from: (source, sourceFolder.appending(path: "dicts")),
                             to: (destination, destinationFolder.appending(path: "dicts")))

        let titles = try destination.reader.read { try String.fetchAll($0, sql: "SELECT title FROM dictionary") }
        #expect(titles == ["A"])
        let folders = try FileManager.default.contentsOfDirectory(atPath: destinationFolder.appending(path: "dicts").path(percentEncoded: false))
        #expect(folders == ["id-A"])
        #expect(try AnkiSettingsStore(database: destination).settings().deck == "Deck A")
        #expect(try AccountStore(database: destination).account(.anki)?.baseURL.host() == "anki-A.local")
        // Servers aren't part of the setup.
        #expect(try AccountStore(database: destination).account(.kavita)?.baseURL.host() == "mine.local")
    }

    @Test func emptyMeansNoDictionariesAndNoAnki() throws {
        let database = try AppDatabase.inMemory()
        #expect(try SharedSetup.isEmpty(database))
        try AccountStore(database: database).save(ServerAccount(kind: .anki, baseURL: URL(string: "http://anki.local")!))
        #expect(try !SharedSetup.isEmpty(database))
    }

    @Test func ankiAccountGoesToTheSharedSetup() async throws {
        let own = try AppDatabase.inMemory(), shared = try AppDatabase.inMemory()
        let accounts = AccountStore(database: own, shared: shared)
        try accounts.save(ServerAccount(kind: .anki, baseURL: URL(string: "http://anki.local")!))
        try accounts.save(ServerAccount(kind: .kavita, baseURL: URL(string: "http://kavita.local")!))
        #expect(try AccountStore(database: shared).account(.anki) != nil)
        #expect(try AccountStore(database: own).account(.anki) == nil)
        #expect(try AccountStore(database: own).account(.kavita) != nil)
        var ownAccounts = accounts.observeAll().makeAsyncIterator()
        #expect(try await ownAccounts.next()?.keys.sorted { $0.rawValue < $1.rawValue } == [.kavita])
        var sharedAccounts = accounts.observeShared().makeAsyncIterator()
        #expect(try await sharedAccounts.next()?.keys.sorted { $0.rawValue < $1.rawValue } == [.anki])
    }

    @Test func twoProcessesSeeTheSameFile() throws {
        let folder = temporary("shared")
        let first = try SharedSetup(root: folder).openDatabase(), second = try SharedSetup(root: folder).openDatabase()
        try AccountStore(database: first).save(ServerAccount(kind: .anki, baseURL: URL(string: "http://anki.local")!))
        #expect(try AccountStore(database: second).account(.anki) != nil)
    }

    @Test func changesAreAnnounced() async throws {
        let queue = DispatchQueue(label: "setup-changes")
        let received = Mutex(false)
        let observation = SharedSetup.observeChanges(queue: queue) { received.withLock { $0 = true } }
        SharedSetup.postChanged()
        for _ in 0..<50 where !received.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(20)) }
        #expect(received.withLock { $0 })
        _ = observation
    }
}

@Suite struct RoutingSecretStoreTests {
    struct Unavailable: SecretStore {
        struct Missing: Error {}
        func secret(for key: SecretKey) throws -> String? { throw Missing() }
        func setSecret(_ value: String?, for key: SecretKey) throws { throw Missing() }
    }

    @Test func ankiKeyIsSharedOtherKeysStayOwn() throws {
        let own = InMemorySecretStore(), shared = InMemorySecretStore()
        let store = RoutingSecretStore(own: own, shared: shared)
        try store.setSecret("anki", for: .ankiAPIKey)
        try store.setSecret("kavita", for: .kavitaAuthKey)
        #expect(try shared.secret(for: .ankiAPIKey) == "anki" && own.secret(for: .ankiAPIKey) == nil)
        #expect(try own.secret(for: .kavitaAuthKey) == "kavita" && shared.secret(for: .kavitaAuthKey) == nil)
    }

    @Test func fallsBackWhenTheSharedKeychainIsUnavailable() throws {
        let own = InMemorySecretStore()
        let store = RoutingSecretStore(own: own, shared: Unavailable())
        try store.setSecret("anki", for: .ankiAPIKey)
        #expect(try store.secret(for: .ankiAPIKey) == "anki")
    }
}
