import AppIntents
import Foundation

/// What the intents do, filled in by Kiku at launch. The intents are audio playback intents,
/// which the system always runs inside Kiku (started in the background if it isn't running),
/// so these are set whenever they're called; in the widget extension they're never used.
@MainActor
public final class KikuControls {
    public static let shared = KikuControls()
    /// Plays what's loaded, or the episode or book last played. Nil when there's nothing.
    public var resume: () async -> String? = { nil }
    /// Marks the moment playing; the position, or nil with nothing playing.
    public var mark: () -> Double? = { nil }
}

/// "Resume in Kiku": Siri, Shortcuts, the widgets' play button and Control Center.
public struct ResumeIntent: AudioPlaybackIntent {
    public static let title: LocalizedStringResource = "Resume Listening"
    public static let description = IntentDescription("Plays the episode or book you were listening to in Kiku.")

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let title = await KikuControls.shared.resume() else {
            return .result(dialog: "There's nothing to resume in Kiku.")
        }
        return .result(dialog: "Playing \(title).")
    }
}

/// "Mark in Kiku": marks what's playing without opening the app (the Action Button, Siri,
/// Back Tap, Shortcuts and Control Center).
public struct MarkIntent: AudioPlaybackIntent {
    public static let title: LocalizedStringResource = "Mark What I Just Heard"
    public static let description = IntentDescription("Marks the moment in the episode playing in Kiku, to mine later from Marks.")

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let time = KikuControls.shared.mark() else {
            return .result(dialog: "Nothing is playing in Kiku.")
        }
        let seconds = Int(time)
        let text = seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
        return .result(dialog: "Marked \(text).")
    }
}

/// The intents, for the app's shortcuts and the widget extension.
public struct KikuIntentsPackage: AppIntentsPackage {}
