import SwiftUI
import WatchConnectivity
import WatchKit

/// Kiku on Apple Watch: a remote for Kiku on the iPhone, with Mark (docs/watch.md), and the
/// episodes and books sent to it (docs/KIKU_PLAN.md milestone 2).
@main
struct KikuWatchApp: App {
    @WKApplicationDelegateAdaptor private var delegate: KikuWatchAppDelegate
    @State private var session = WatchSession.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            NavigationStack { NowPlayingScreen() }
                .tint(Color("AccentColor"))
                .environment(session)
                .task { session.start() }
        }
        .onChange(of: scenePhase) { _, phase in
            // Downloads made no progress reports while suspended: tell the phone where they are.
            if phase == .active { Task { await session.downloads.reconcile() } }
        }
    }
}

/// Wakes for the downloads' background session: its events are delivered to `WatchDownloads`
/// (made with the same identifier), and the task completes once they're in.
final class KikuWatchAppDelegate: NSObject, WKApplicationDelegate {
    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        for task in backgroundTasks {
            if let urlTask = task as? WKURLSessionRefreshBackgroundTask, urlTask.sessionIdentifier == WatchDownloads.sessionIdentifier {
                WatchSession.shared.downloads.handleBackgroundEvents { urlTask.setTaskCompletedWithSnapshot(false) }
            } else if let connectivity = task as? WKWatchConnectivityRefreshBackgroundTask {
                // The phone's list (or listening's acknowledgement) is waiting: start the session
                // and hold the task until it's delivered, so the downloads start without opening the app.
                WatchSession.shared.start()
                Self.complete(connectivity)
            } else {
                task.setTaskCompletedWithSnapshot(false)
            }
        }
    }

    /// Done once WatchConnectivity has nothing more to hand over (checked for up to 20 s).
    private static func complete(_ task: WKWatchConnectivityRefreshBackgroundTask, tries: Int = 0) {
        if !WCSession.default.hasContentPending || tries >= 40 {
            // A moment for the list's downloads to be queued.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { task.setTaskCompletedWithSnapshot(false) }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { complete(task, tries: tries + 1) }
    }
}
