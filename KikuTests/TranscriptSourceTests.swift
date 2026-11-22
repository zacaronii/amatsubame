import AudiobookshelfKit
import Core
import Foundation
@testable import Kiku
import Testing

/// What made a transcript, and telling Kaku's newer one from the saved copy (#149).
@MainActor @Suite struct TranscriptSourceTests {
    func document(createdAt: String?) throws -> KakuTranscript {
        let created = createdAt.map { #", "createdAt": "\#($0)""# } ?? ""
        let json = #"{"item": {"libraryItemId": "i", "episodeId": "e"}, "source": {"fingerprint": "f", "model": "large-v3", "kaku": "1.6.0"\#(created)}, "sentences": []}"#
        return try JSONDecoder().decode(KakuTranscript.self, from: Data(json.utf8))
    }

    func saved(_ transcribedAt: Date?) -> AudioTranscriptInfo {
        AudioTranscriptInfo(itemId: "i", episodeId: "e", showTitle: "S", episodeTitle: "E", fingerprint: "f", duration: 60,
                            savedAt: Date(timeIntervalSince1970: 1_793_900_000), model: "large-v3", kakuVersion: "1.6.0",
                            transcribedAt: transcribedAt)
    }

    @Test func aTranscriptMadeAtAnotherTimeIsNewer() throws {
        let made = Date(timeIntervalSince1970: 1_793_867_403)
        let same = try document(createdAt: "2026-11-05T08:30:03+00:00")
        #expect(!PlaybackModel.isNewer(same, than: saved(made)))
        #expect(PlaybackModel.isNewer(try document(createdAt: "2026-11-21T10:00:00+00:00"), than: saved(made)))
        #expect(PlaybackModel.isNewer(same, than: saved(nil)), "a copy from before the source was kept is filled in")
        #expect(!PlaybackModel.isNewer(try document(createdAt: nil), than: saved(made)))
    }

    @Test func theMenuSaysWhatMadeIt() {
        let text = PlaybackModel.sourceText(saved(Date(timeIntervalSince1970: 1_793_867_403)))
        #expect(text.hasPrefix("large-v3 · Kaku 1.6.0 · "))
        #expect(text.contains("2026"))
    }

    /// Pulling the player down: far enough, or a shorter flick; a nudge springs back.
    @Test func pullingThePlayerDownClosesItWhenMeant() {
        #expect(PlayerView.pullCloses(translation: 200, predicted: 220))
        #expect(PlayerView.pullCloses(translation: 60, predicted: 500), "a flick")
        #expect(PlayerView.pullCloses(translation: 120, predicted: 130), "pulled far, slowly")
        #expect(!PlayerView.pullCloses(translation: 60, predicted: 90), "a nudge")
        #expect(!PlayerView.pullCloses(translation: 10, predicted: 900), "barely moved")
    }
}
