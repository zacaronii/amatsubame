@testable import AppCommon
import Core
import Foundation
import HachidoriKit
import Testing

/// Which dictionary on the device a host dictionary is: the same title, or the same download
/// link when a newer release put its date in the title.
@MainActor @Suite struct HachidoriDictionaryCopyTests {
    func host(_ title: String, downloadUrl: String? = nil) throws -> HostDictionary {
        var fields: [String: Any] = ["id": UUID().uuidString, "title": title, "enabled": true]
        if let downloadUrl { fields["downloadUrl"] = downloadUrl }
        return try JSONDecoder().decode(HostDictionary.self, from: JSONSerialization.data(withJSONObject: fields))
    }

    @Test func matchesByTitleThenByDownloadLink() throws {
        let link = "https://github.com/stephenmk/stephenmk.github.io/releases/latest/download/jitendex-yomitan.zip"
        let local = [DictionaryRecord(id: "a", title: "Jitendex.org [2026-10-03]"), DictionaryRecord(id: "b", title: "Jiten")]
        let sources = ["a": DictionarySource(dictionaryId: "a", downloadUrl: link)]
        #expect(HachidoriDictionaryCopy.match(try host("Jiten"), in: local, sources: sources)?.id == "b")
        #expect(HachidoriDictionaryCopy.match(try host("Jitendex.org [2026-11-14]", downloadUrl: link), in: local, sources: sources)?.id == "a")
        #expect(HachidoriDictionaryCopy.match(try host("JMnedict [2026-11-13]"), in: local, sources: sources) == nil)
        #expect(HachidoriDictionaryCopy.match(try host("Other", downloadUrl: "https://example.com/x.zip"), in: local, sources: sources) == nil)
    }
}
