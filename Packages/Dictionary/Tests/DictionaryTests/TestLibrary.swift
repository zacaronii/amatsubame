import Core
import Dictionary
import DictionaryTestSupport
import Foundation

/// A library in a fresh temporary directory with an in-memory database.
func makeLibrary() throws -> DictionaryLibrary {
    DictionaryLibrary(
        database: try AppDatabase.inMemory(),
        directory: FileManager.default.temporaryDirectory.appending(path: "dict-tests-\(UUID().uuidString)")
    )
}

struct TransformFixture: Decodable {
    struct Case: Decodable {
        var category: String
        var valid: Bool
        var term: String
        var source: String
        var rule: String?
        var reasons: [String]?
    }
    var terms: [String: String]
    var cases: [Case]

    static func load() throws -> TransformFixture {
        let url = Bundle.module.url(forResource: "yomitan-japanese-transforms", withExtension: "json", subdirectory: "Fixtures")!
        return try JSONDecoder().decode(TransformFixture.self, from: Data(contentsOf: url))
    }
}
