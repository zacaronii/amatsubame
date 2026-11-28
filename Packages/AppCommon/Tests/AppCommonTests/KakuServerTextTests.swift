import AudiobookshelfKit
import Foundation
import Testing
@testable import AppCommon

/// The line under each library on the Kaku screen.
@MainActor struct KakuServerTextTests {
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

    /// The line under Kaku in each app's Settings.
    @Test func theSettingsRowSaysWhatKakuIsDoing() throws {
        func health(_ jobs: String) throws -> KakuHealth {
            try JSONDecoder().decode(KakuHealth.self, from: Data(#"{"version": "1.5.0", "jobs": \#(jobs)}"#.utf8))
        }
        func summary(_ host: String?, _ health: KakuHealth? = nil, unreachable: Bool = false) -> String {
            KakuSettingsRow.summary(host: host, health: health, unreachable: unreachable)
        }
        #expect(summary(nil) == "Optional · your own transcription server")
        #expect(summary("kaku.example") == "kaku.example")
        #expect(summary("kaku.example", unreachable: true) == "Can't reach kaku.example")
        #expect(summary("kaku.example", try health(#"{"done": 155}"#)) == "Idle · 155 transcribed")
        #expect(summary("kaku.example", try health(#"{"done": 155, "running": 1}"#)) == "Transcribing")
        #expect(summary("kaku.example", try health(#"{"done": 155, "running": 1, "queued": 9, "failed": 2}"#)) == "Transcribing · 9 waiting · 2 failed")
        #expect(summary("kaku.example", try health(#"{"done": 155, "failed": 1}"#)) == "Idle · 155 transcribed · 1 failed")
    }
}
