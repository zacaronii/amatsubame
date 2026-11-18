import SwiftUI

/// Kiku on Apple Watch: a remote for Kiku on the iPhone, with Mark (docs/watch.md).
@main
struct KikuWatchApp: App {
    @State private var session = WatchSession()

    var body: some Scene {
        WindowGroup {
            NowPlayingScreen()
                .tint(Color("AccentColor"))
                .environment(session)
                .task { session.start() }
        }
    }
}
