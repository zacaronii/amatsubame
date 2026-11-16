import Dictionary
import DictionaryTestSupport
import Foundation
import Testing

/// Folders compiled elsewhere (a Hachidori host's exports) install without an import.
@Suite struct CompiledInstallTests {
    /// A compiled folder of a one-word dictionary, as a host export unpacks to.
    func compiledFolder(title: String = "Host Terms", revision: String = "1", gloss: String = "to eat") throws -> URL {
        var builder = TestDictionaryBuilder(title: title, revision: revision)
        builder.terms = [.init("食べる", "たべる", rules: "v1", glossary: [gloss])]
        let package = FileManager.default.temporaryDirectory.appending(path: "compiled-\(UUID().uuidString)")
        try DictionaryLibrary.prebuild(zip: try builder.write(), into: package)
        return try #require(try FileManager.default.contentsOfDirectory(at: package, includingPropertiesForKeys: nil).first(where: \.hasDirectoryPath))
    }

    @Test func installsAndLooksUp() async throws {
        let library = try makeLibrary()
        let outcome = try await library.installCompiled(try compiledFolder(), kinds: .init(terms: 1))
        #expect(outcome.dictionary.title == "Host Terms" && outcome.dictionary.revision == "1")
        #expect(outcome.dictionary.hasTerms && !outcome.dictionary.hasFrequencies)
        #expect(await library.engine.lookup("食べた").first?.expression == "食べる")
    }

    @Test func theSameRevisionIsAlreadyInstalledANewerOneReplaces() async throws {
        let library = try makeLibrary()
        let first = try await library.installCompiled(try compiledFolder(revision: "1"), kinds: .init(terms: 1)).dictionary
        await #expect(throws: DictionaryError.alreadyInstalled(title: "Host Terms", revision: "1")) {
            try await library.installCompiled(try compiledFolder(revision: "1"), kinds: .init(terms: 1))
        }
        let second = try await library.installCompiled(try compiledFolder(revision: "2", gloss: "new"), kinds: .init(terms: 1))
        #expect(second.replacedPrevious && second.dictionary.id == first.id)
        #expect(await library.engine.lookup("食べる").first?.glossaries.first?.json == #"["new"]"#)
    }

    @Test func aNewerFormatIsRefused() async throws {
        let library = try makeLibrary()
        let folder = try compiledFolder()
        let marker = try #require(try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false)).first { $0.hasPrefix(".hoshidicts_") })
        try FileManager.default.moveItem(at: folder.appending(path: marker), to: folder.appending(path: ".hoshidicts_99"))
        await #expect(throws: DictionaryError.newerFormat) {
            try await library.installCompiled(folder, kinds: .init(terms: 1))
        }
        #expect(try library.dictionaries().isEmpty)
    }
}
