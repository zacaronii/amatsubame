import AppCommon
import Readers
import SwiftUI
#if os(iOS)
import BackgroundTasks
#endif

#if os(iOS)
/// Only for the readers' Lock Rotation: which orientations the app may turn to right now.
final class YomuAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        OrientationLock.mask
    }
}
#endif

@main
struct YomuApp: App {
    static let outboxRefreshTask = "com.amatsubame.yomu.outbox"

    @State private var environment = AppEnvironment.live()
    @Environment(\.scenePhase) private var scenePhase
    #if os(iOS)
    @UIApplicationDelegateAdaptor(YomuAppDelegate.self) private var appDelegate
    #endif

    var body: some Scene {
        WindowGroup {
            RootView()
                // The app's AccentColor (Yomu green, Miru purple); the Info.plist accent alone wasn't applied.
                .tint(Color("AccentColor"))
                .environment(environment)
                .environment(environment.common)
                .task { await environment.start() }
        }
        .commands { ReaderMenus(environment: environment) }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                environment.syncNow(retryWaiting: true)
                environment.autoDownloads.schedule()
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
            AboutCommands(appCredits: SettingsView.credits)
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

/// Menu bar: the Reader menu (acts on the volume being read) and tab shortcuts.
struct ReaderMenus: Commands {
    let environment: AppEnvironment
    @FocusedValue(\.readerPaging) private var paging
    @FocusedValue(\.readerClose) private var close
    @FocusedValue(\.bookSearch) private var bookSearch

    /// ⌘1… for each tab; on the Mac, Settings is ⌘, instead.
    static var shortcutTabs: [AppTab] {
        #if os(macOS)
        AppTab.allCases.filter { $0 != .settings }
        #else
        AppTab.allCases
        #endif
    }

    var body: some Commands {
        CommandMenu("Reader") {
            Button("Next Page") { paging?.next() }
                .keyboardShortcut(.pageDown, modifiers: [])
                .disabled(paging == nil)
            Button("Previous Page") { paging?.previous() }
                .keyboardShortcut(.pageUp, modifiers: [])
                .disabled(paging == nil)
            Divider()
            Button("Back to Library") { close?() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(close == nil)
            // While a book is open, ⌘F searches it and Search Dictionary moves to ⇧⌘F.
            if let bookSearch {
                Button("Search the Book") { bookSearch() }
                    .keyboardShortcut("f", modifiers: .command)
            }
            Button("Search Dictionary") {
                close?()
                environment.selectedTab = .dictionary
            }
            .keyboardShortcut("f", modifiers: bookSearch == nil ? .command : [.command, .shift])
        }
        CommandGroup(after: .sidebar) {
            RefreshCommand()
            Divider()
            ForEach(Array(Self.shortcutTabs.enumerated()), id: \.offset) { index, tab in
                Button(tab.title) {
                    close?()
                    environment.selectedTab = tab
                }
                .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
            }
        }
    }
}
