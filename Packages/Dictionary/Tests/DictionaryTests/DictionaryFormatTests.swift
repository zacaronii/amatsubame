import Core
import Dictionary
import DictionaryTestSupport
import Foundation
import Testing

@Suite struct DictionaryFormatTests {
    func termDictionary(_ title: String, _ expression: String, _ reading: String) -> TestDictionaryBuilder {
        var builder = TestDictionaryBuilder(title: title)
        builder.terms = [.init(expression, reading, glossary: [title])]
        return builder
    }

    @Test func anImportIsInAFormatTheEngineReads() async throws {
        let library = try makeLibrary()
        let record = try await library.importDictionary(at: try termDictionary("Terms", "食べる", "たべる").write()).dictionary
        let format = DictionaryFormat(folder: library.folder(for: record))
        #expect(format == .supported(5) || format == .supported(6))
        #expect(format.problem == nil)
    }

    @Test func aNewerFormatIsLeftOutAndTheOthersKeepWorking() async throws {
        let library = try makeLibrary()
        let newer = try await library.importDictionary(at: try termDictionary("Newer", "食べる", "たべる").write()).dictionary
        _ = try await library.importDictionary(at: try termDictionary("Older", "飲む", "のむ").write())

        // As a folder copied from a host whose engine is ahead of ours would be.
        let folder = library.folder(for: newer)
        let marker = try #require(try FileManager.default.contentsOfDirectory(atPath: folder.path()).first { $0.hasPrefix(".hoshidicts_") })
        try FileManager.default.moveItem(at: folder.appending(path: marker), to: folder.appending(path: ".hoshidicts_99"))
        #expect(DictionaryFormat(folder: folder) == .newer(99))
        #expect(DictionaryFormat(folder: folder).problem != nil)

        try await library.reloadEngine()
        #expect(await library.engine.dictionaries.map(\.title) == ["Older"])
        #expect(await library.engine.lookup("食べる").isEmpty)
        #expect(await library.engine.lookup("飲む").first?.expression == "飲む")
    }

    @Test func aFolderWithoutAMarkerIsMissing() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "format-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #expect(DictionaryFormat(folder: folder) == .missing)
    }

    @Test func fractionalScoresSurviveImportAndLookup() async throws {
        let library = try makeLibrary()
        var builder = TestDictionaryBuilder(title: "Scores")
        builder.terms = [.init("生", "なま", glossary: ["raw"], score: 0.5), .init("生", "せい", glossary: ["life"], score: 1.25)]
        _ = try await library.importDictionary(at: try builder.write())
        let scores = await library.engine.lookup("生").map(\.score)
        #expect(Set(scores) == [0.5, 1.25])
    }
}
