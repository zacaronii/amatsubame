import AudiobookshelfKit
import Core
import Foundation

/// What made a Kaku transcript, and asking for a fresh one (#149): Kiku's player and Yomu's
/// read-along say the same.
nonisolated public enum KakuTranscriptSource {
    /// "anime-whisper · Kaku 1.7.0 · 5 Nov 2026"; "Saved 5 Nov 2026" for a copy kept from before
    /// the model was recorded (only `saved` known).
    public static func text(model: String?, kaku: String?, made: Date?, saved: Date?) -> String {
        let date = (made ?? saved)?.formatted(date: .abbreviated, time: .omitted)
        let text = [model, kaku.map { "Kaku \($0)" }, date].compactMap(\.self).joined(separator: " · ")
        return model == nil && kaku == nil ? "Saved \(text)" : text
    }

    /// Asks Kaku (1.6 or newer) to transcribe an episode or book again, first in its queue; the
    /// old transcript serves until the new one replaces it. What to tell the reader.
    public static func requestAgain(_ kaku: KakuClient, itemId: String, episodeId: String, whenDone: String) async -> String {
        do {
            guard try await kaku.requestJob(itemId: itemId, episodeId: episodeId, force: true) != nil else {
                // An older Kaku ignores `force` and answers that the transcript is current.
                return "Kaku needs to be 1.6 or newer to transcribe again."
            }
            return "Kaku is transcribing it again. \(whenDone)"
        } catch {
            return "Couldn't reach Kaku. \(error.localizedDescription)"
        }
    }
}
