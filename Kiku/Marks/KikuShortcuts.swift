import AppIntents
import KikuIntents

/// Siri and Shortcuts: "Mark in Kiku" and "Resume in Kiku" (the intents are in KikuIntents,
/// shared with the widgets; they run inside Kiku).
struct KikuShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: MarkIntent(),
                    phrases: ["Mark in \(.applicationName)", "Mark this in \(.applicationName)"],
                    shortTitle: "Mark", systemImageName: "bookmark")
        AppShortcut(intent: ResumeIntent(),
                    phrases: ["Resume in \(.applicationName)", "Continue listening in \(.applicationName)"],
                    shortTitle: "Resume", systemImageName: "play.fill")
    }
}

extension KikuApp: AppIntentsPackage {
    static var includedPackages: [any AppIntentsPackage.Type] { [KikuIntentsPackage.self] }
}
