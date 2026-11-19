import SwiftUI
import WatchKit

/// Kiku on Apple Watch: a remote for Kiku on the iPhone, with Mark (docs/watch.md), and the
/// episodes and books sent to it (docs/KIKU_PLAN.md milestone 2).
@main
struct KikuWatchApp: App {
    @WKApplicationDelegateAdaptor private var delegate: KikuWatchAppDelegate
    @State private var session = WatchSession.shared

    var body: some Scene {
        WindowGroup {
            NavigationStack { NowPlayingScreen() }
                .tint(Color("AccentColor"))
                .environment(session)
                .task { session.start() }
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
            } else {
                task.setTaskCompletedWithSnapshot(false)
            }
        }
    }
}
