import SwiftUI
#if os(iOS)
import AetherBridge
import JellyfinKit
#endif

/// Spike (never merged): Settings ▸ Test ▸ "Play with AetherEngine" sends episodes to AetherEngine's
/// test player instead of Miru's mpv player. Off by default.
enum AetherTest {
    static let key = "spike.aetherTestPlayer"
    static var isOn: Bool { UserDefaults.standard.bool(forKey: key) }
}

#if os(iOS)

/// The original file (a download, else Jellyfin's direct stream) at the resume point, in AetherEngine.
/// Nothing is reported to Jellyfin: no progress, no "watched".
struct AetherTestPlayback: View {
    @Environment(PlayerEnvironment.self) private var environment
    let session: PlaybackSession
    let onClose: () -> Void
    @State private var source: (url: URL, headers: [String: String], start: Double)?
    @State private var error: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let source {
                AetherTestPlayerView(url: source.url, headers: source.headers, start: source.start, onClose: onClose)
                    .ignoresSafeArea(edges: .bottom)
            } else if let error {
                VStack(spacing: 16) {
                    Text(error).foregroundStyle(.white)
                    Button("Close", action: onClose)
                }
                .padding()
            } else {
                ProgressView().tint(.white)
            }
        }
        .task { await resolve() }
    }

    private func resolve() async {
        #if DEBUG
        // UI tests: a local video file (UITEST_PLAYER_VIDEO) instead of a Jellyfin item.
        if session.itemId.hasPrefix("/") {
            source = (URL(filePath: session.itemId), [:], 0)
            return
        }
        #endif
        if let file = environment.downloader.localFile(itemId: session.itemId) {
            let resume = environment.downloader.metadata(itemId: session.itemId)?.item.resumePosition ?? 0
            source = (file, [:], session.startAt ?? resume)
            return
        }
        guard let client = environment.jellyfinClient() else {
            error = "Sign in to Jellyfin in Settings."
            return
        }
        do {
            let item = try await client.item(id: session.itemId)
            let info = try await client.playbackInfo(itemId: session.itemId)
            guard let sourceId = (info.mediaSources.first ?? item.mediaSources?.first)?.id else {
                error = "Jellyfin has no playable file for this item."
                return
            }
            source = (client.streamURL(itemId: item.id, mediaSourceId: sourceId, playSessionId: info.playSessionId),
                      client.playbackHeaders, session.startAt ?? item.resumePosition ?? 0)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct AetherTestPlayerView: UIViewControllerRepresentable {
    let url: URL
    let headers: [String: String]
    let start: Double
    let onClose: () -> Void

    func makeUIViewController(context: Context) -> UIViewController {
        do {
            let controller = try AetherTestPlayerController(url: url, headers: headers, start: start)
            controller.onClose = onClose
            return controller
        } catch {
            let failed = UIHostingController(rootView: VStack(spacing: 16) {
                Text("AetherEngine didn't start: \(error.localizedDescription)")
                Button("Close", action: onClose)
            }.padding())
            return failed
        }
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {}
}
#endif
