import AppCommon
import AppIntents
import SwiftUI
#if os(iOS)
import BackgroundTasks
#endif

@main
struct KikuApp: App {
    static let outboxRefreshTask = "com.amatsubame.kiku.outbox"

    @State private var environment: KikuEnvironment
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let environment = KikuEnvironment.live()
        _environment = State(initialValue: environment)
        // For "Mark in Kiku" (the Action Button and Siri).
        AppDependencyManager.shared.add(dependency: environment)
    }

    var body: some Scene {
        WindowGroup {
            KikuRootView()
                // Kiku orange; the Info.plist accent alone isn't applied.
                .tint(Color("AccentColor"))
                .environment(environment)
                .environment(environment.common)
                .task { await environment.start() }
                .onChange(of: environment.common.reachability.reconnections) { environment.retryConnections() }
        }
        .commands { KikuMenus(environment: environment) }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                environment.common.syncNow(retryWaiting: true)
                environment.retryConnections()
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

/// Menu bar: tab shortcuts.
struct KikuMenus: Commands {
    let environment: KikuEnvironment

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            ForEach(Array(KikuTab.allCases.enumerated()), id: \.offset) { index, tab in
                Button(tab.title) { environment.selectedTab = tab }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
            }
        }
    }
}
