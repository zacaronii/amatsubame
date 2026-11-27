import AppCommon
import SwiftUI
#if os(iOS)
import BackgroundTasks
#endif

@main
struct MiruApp: App {
    static let outboxRefreshTask = "com.amatsubame.miru.outbox"

    @State private var environment = PlayerEnvironment.live()
    #if os(iOS)
    /// Routes a connected screen's scene to the external display's window.
    @UIApplicationDelegateAdaptor(MiruAppDelegate.self) private var appDelegate
    #endif
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if let lab = EngineLab.make() {
                EngineLabView(lab: lab)
            } else {
                PlayerRootView()
                    .tint(Color("AccentColor"))
                    .environment(environment)
                    .environment(environment.common)
                    .task { await environment.start() }
                    .task { await environment.renewDemo() }
            }
            #else
            PlayerRootView()
                // The app's AccentColor (Yomu green, Miru purple); the Info.plist accent alone wasn't applied.
                .tint(Color("AccentColor"))
                .environment(environment)
                .environment(environment.common)
                .task { await environment.start() }
                .task { await environment.renewDemo() }
            #endif
        }
        .commands { PlayerMenus(environment: environment) }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                environment.common.syncNow(retryWaiting: true)
                Task { await environment.renewDemo() }
            case .background:
                scheduleOutboxRefresh()
                environment.common.statsSync.send()
            default: break
            }
        }
        #if os(iOS)
        .backgroundTask(.appRefresh(Self.outboxRefreshTask)) {
            await environment.common.worker.drain()
            await scheduleOutboxRefresh()
        }
        // iOS relaunches the app when background episode downloads finish.
        .backgroundTask(.urlSession(EpisodeDownloader.sessionIdentifier)) {
            await environment.downloader.handleBackgroundEvents()
        }
        #endif
        #if os(macOS)
        // ⌘, : Settings in its own window, its pages in a sidebar. A window rather than a
        // Settings scene, whose toolbar puts a page's back button under its title.
        Window("Settings", id: MacSettingsWindow.sceneID) {
            MacSettingsView()
                .tint(Color("AccentColor"))
                .environment(environment)
                .environment(environment.common)
        }
        .defaultSize(width: 860, height: 640)
        .windowResizability(.contentMinSize)
        .commands {
            MacSettingsCommands()
            AboutCommands(appCredits: PlayerSettingsView.credits)
        }
        #endif
    }

    /// Asks iOS to wake the app later to send anything still queued.
    private func scheduleOutboxRefresh() {
        #if os(iOS)
        let request = BGAppRefreshTaskRequest(identifier: Self.outboxRefreshTask)
        request.earliestBeginDate = .now.addingTimeInterval(15 * 60)
        try? BGTaskScheduler.shared.submit(request)
        #endif
    }
}

/// Menu bar: Playback (acts on the player in front) and tab shortcuts.
struct PlayerMenus: Commands {
    let environment: PlayerEnvironment

    /// ⌘1… for each tab; on the Mac, Settings is ⌘, instead.
    static var shortcutTabs: [PlayerTab] {
        #if os(macOS)
        PlayerTab.allCases.filter { $0 != .settings }
        #else
        PlayerTab.allCases
        #endif
    }
    @FocusedValue(\.playback) private var playback

    /// Off while a sheet you type in is open (dictionary search, Find Subtitles), so typing
    /// there isn't taken as commands.
    private var player: PlaybackModel? {
        playback.flatMap { $0.showsSearch || $0.showsSubtitleSearch || $0.showsSubtitlesSheet ? nil : $0 }
    }

    @ViewBuilder private func menuItem(_ shortcut: PlayerShortcut) -> some View {
        let button = Button(title(shortcut)) { player?.perform(shortcut) }
            .disabled(player == nil || (shortcut == .skip && player?.skipTitle == nil))
        // The Mac's menu takes the keys. On an iPad the player reads them itself: menu key
        // commands there match Shift-[ as [ some of the time.
        #if os(macOS)
        if let key = shortcut.menuShortcut {
            button.keyboardShortcut(key)
        } else {
            button
        }
        #else
        button
        #endif
    }

    /// The Subtitles menu: the lines and the subtitles. Everything else is in Playback.
    static let subtitleSections: [PlayerShortcut.Section] = [.lines, .subtitles]
    static let playbackSections = PlayerShortcut.Section.allCases.filter { !subtitleSections.contains($0) }

    @ViewBuilder private func menuSections(_ sections: [PlayerShortcut.Section]) -> some View {
        ForEach(sections) { section in
            ForEach(PlayerShortcut.available.filter { $0.section == section }) { shortcut in
                menuItem(shortcut)
            }
            if section != sections.last { Divider() }
        }
    }

    /// The menu's wording follows what the item would do now.
    private func title(_ shortcut: PlayerShortcut) -> String {
        switch shortcut {
        case .playPause: player?.mpv.isPaused == false ? "Pause" : "Play"
        case .skip: player?.skipTitle ?? shortcut.title
        case .english: player?.showsEnglish == true ? "Hide English Subtitles" : "Show English Subtitles"
        case .mute: player?.mpv.isMuted == true ? "Unmute" : "Mute"
        default: shortcut.title
        }
    }

    var body: some Commands {
        // Built from PlayerShortcut, like the keys and the cheat sheet.
        CommandMenu("Playback") { menuSections(Self.playbackSections) }
        CommandMenu("Subtitles") { menuSections(Self.subtitleSections) }
        CommandGroup(after: .sidebar) {
            RefreshCommand()
            Divider()
            ForEach(Array(Self.shortcutTabs.enumerated()), id: \.offset) { index, tab in
                Button(tab.title) { environment.selectedTab = tab }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
            }
        }
    }
}
