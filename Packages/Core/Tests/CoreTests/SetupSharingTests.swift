import Core
import Foundation
import Testing

@Suite struct SetupSharingTests {
    struct App {
        let database: AppDatabase
        let dictionaries: URL
        let secrets = InMemorySecretStore()
    }

    let sharedSecrets = InMemorySecretStore()
    let shared: SharedSetup
    let sharedDatabase: AppDatabase

    init() throws {
        shared = SharedSetup(root: FileManager.default.temporaryDirectory.appending(path: "shared-\(UUID().uuidString)"))
        sharedDatabase = try shared.openDatabase()
    }

    func makeApp(withSetup title: String? = nil) throws -> App {
        let folder = FileManager.default.temporaryDirectory.appending(path: "app-\(UUID().uuidString)")
        let app = App(database: try AppDatabase.onDisk(directory: folder.appending(path: "db")), dictionaries: folder.appending(path: "dicts"))
        if let title {
            try app.database.writer.write { try DictionaryRecord(id: "id-\(title)", title: title, hasTerms: true).insert($0) }
            let dictionary = app.dictionaries.appending(path: "id-\(title)")
            try FileManager.default.createDirectory(at: dictionary, withIntermediateDirectories: true)
            try Data(title.utf8).write(to: dictionary.appending(path: "index.bin"))
            try AccountStore(database: app.database).save(ServerAccount(kind: .anki, baseURL: URL(string: "http://anki.local")!))
            try app.secrets.setSecret("key-\(title)", for: .ankiAPIKey)
        }
        return app
    }

    func sharing(_ app: App, name: String = "Test") -> SetupSharing {
        SetupSharing(shared: shared, sharedDatabase: sharedDatabase, own: (app.database, app.dictionaries),
                     ownSecrets: app.secrets, sharedSecrets: sharedSecrets,
                     defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!, appName: name)
    }

    func sharedTitles() throws -> [String] {
        try sharedDatabase.reader.read { try String.fetchAll($0, sql: "SELECT title FROM dictionary ORDER BY title") }
    }

    @Test func theFirstSetUpAppPublishesItsSetup() throws {
        let reader = try makeApp(withSetup: "Jitendex")
        let resolved = try sharing(reader).resolve()
        #expect(resolved.mode == .shared && !resolved.needsChoice)
        #expect(try sharedTitles() == ["Jitendex"])
        #expect(FileManager.default.fileExists(atPath: shared.dictionaryDirectory.appending(path: "id-Jitendex/index.bin").path(percentEncoded: false)))
        #expect(try sharedSecrets.secret(for: .ankiAPIKey) == "key-Jitendex")
    }

    @Test func theMembersSayWhichAppsShare() throws {
        _ = try sharing(try makeApp(withSetup: "Jitendex"), name: "Yomu").resolve()
        let kiku = sharing(try makeApp(), name: "Kiku")
        _ = try kiku.resolve()
        #expect(shared.members == ["Yomu": true, "Kiku": true])
        // Set Up Separately: Kiku stops being listed before it relaunches.
        kiku.keepOwn()
        #expect(shared.members == ["Yomu": true, "Kiku": false])
    }

    @Test func aNewAppFillsInFromTheSharedSetup() throws {
        _ = try sharing(try makeApp(withSetup: "Jitendex")).resolve()
        let browser = try makeApp()
        let resolved = try sharing(browser).resolve()
        #expect(resolved.mode == .shared)
        #expect(resolved.dictionaryDirectory == shared.dictionaryDirectory)
    }

    @Test func anAppWithItsOwnSetupAsksAndKeepsItUntilThen() throws {
        _ = try sharing(try makeApp(withSetup: "Jitendex")).resolve()
        let player = try makeApp(withSetup: "Other")
        let playerSharing = sharing(player)
        let resolved = try playerSharing.resolve()
        #expect(resolved.mode == .own && resolved.needsChoice)
        #expect(try sharedTitles() == ["Jitendex"])
        playerSharing.useShared()
        #expect(try playerSharing.resolve().mode == .shared)
    }

    @Test func leavingGivesTheAppItsOwnCopy() throws {
        let app = try makeApp(withSetup: "Jitendex")
        let appSharing = sharing(app)
        _ = try appSharing.resolve()
        // Changed while shared: the shared setup has a second dictionary now.
        try sharedDatabase.writer.write { try DictionaryRecord(id: "id-Pitch", title: "Pitch").insert($0) }
        try appSharing.leave()
        let resolved = try appSharing.resolve()
        #expect(resolved.mode == .own)
        let own = try app.database.reader.read { try String.fetchAll($0, sql: "SELECT title FROM dictionary ORDER BY title") }
        #expect(own == ["Jitendex", "Pitch"])
        #expect(try app.secrets.secret(for: .ankiAPIKey) == "key-Jitendex")
        // Later changes to the shared setup don't reach it.
        try sharedDatabase.writer.write { try DictionaryRecord(id: "id-New", title: "New").insert($0) }
        #expect(try app.database.reader.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM dictionary") } == 2)
    }

    @Test func joiningAnEmptySharedSetupPublishes() throws {
        let app = try makeApp(withSetup: "Jitendex")
        let appSharing = sharing(app)
        appSharing.keepOwn()
        #expect(try appSharing.resolve().mode == .own)
        #expect(try sharedTitles().isEmpty)
        try appSharing.join()
        #expect(try appSharing.resolve().mode == .shared)
        #expect(try sharedTitles() == ["Jitendex"])
    }
}
