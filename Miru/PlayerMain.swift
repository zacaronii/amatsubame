import AppCommon
import SwiftUI
#if os(iOS)
import BackgroundTasks
#endif

@main
struct MiruApp: App {
    static let outboxRefreshTask = "com.amatsubame.miru.outbox"

    @State private var environment = PlayerEnvironment.live()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            PlayerRootView()
                // The app's AccentColor (Yomu green, Miru purple); the Info.plist accent alone wasn't applied.
                .tint(Color("AccentColor"))
                .environment(environment)
                .environment(environment.common)
                .task { await environment.start() }
        }
        .commands { PlayerMenus(environment: environment) }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: environment.common.syncNow(retryWaiting: true)
            case .background: scheduleOutboxRefresh()
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
        CommandMenu("Playback") {
            // Built from PlayerShortcut, like the keys and the cheat sheet.
            ForEach(PlayerShortcut.Section.allCases) { section in
                ForEach(PlayerShortcut.available.filter { $0.section == section }) { shortcut in
                    menuItem(shortcut)
                }
                Divider()
            }
        }
        CommandGroup(after: .sidebar) {
            ForEach(Array(PlayerTab.allCases.enumerated()), id: \.offset) { index, tab in
                Button(tab.title) { environment.selectedTab = tab }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
            }
        }
    }
}
