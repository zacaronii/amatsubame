import AppIntents
import Core

/// "Mark in Kiku": marks what's playing without opening the app, for the Action Button, Siri,
/// Back Tap and Shortcuts. An audio playback intent runs inside Kiku itself, so it needs
/// no extension or App Group.
struct MarkIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Mark What I Just Heard"
    static let description = IntentDescription("Marks the moment in the episode playing in Kiku, to mine later from Marks.")

    @Dependency private var environment: KikuEnvironment

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let mark = environment.mark(.shortcut) else {
            return .result(dialog: "Nothing is playing in Kiku.")
        }
        return .result(dialog: "Marked \(mark.time.clockText).")
    }
}

struct KikuShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: MarkIntent(),
                    phrases: ["Mark in \(.applicationName)", "Mark this in \(.applicationName)"],
                    shortTitle: "Mark", systemImageName: "bookmark")
    }
}
