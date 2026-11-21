import AudiobookshelfKit
import Foundation
import Testing
@testable import AppCommon

/// The line under each library on the Kaku screen.
struct KakuServerTextTests {
    func progress(_ json: String) throws -> KakuLibraryProgress {
        try JSONDecoder().decode(KakuLibraryProgress.self, from: Data(json.utf8))
    }

    @Test func oneBookIsSingular() throws {
        let one = try progress(#"{"counts": {"done": 1, "queued": 0, "running": 0, "failed": 0}}"#)
        #expect(KakuServerSections.detail(one, kind: ("book", "books"), enabled: true) == "1 of 1 book transcribed")
    }

    @Test func waitingFailedAndWhen() throws {
        let some = try progress(#"{"counts": {"done": 120, "queued": 9, "running": 1, "failed": 1}, "lastTranscribed": 0}"#)
        let text = KakuServerSections.detail(some, kind: ("episode", "episodes"), enabled: true)
        #expect(text.hasPrefix("120 of 131 episodes transcribed · 10 waiting · 1 failed · updated "))
        #expect(KakuServerSections.detail(some, kind: ("episode", "episodes"), enabled: false) == "Off")
    }
}
