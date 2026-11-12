import AppCommon
import PlayerKit
import SwiftUI

enum PlayerTab: Hashable, CaseIterable {
    case watch, lines, stats, settings

    var title: String {
        switch self {
        case .watch: "Watch"
        case .lines: "Lines"
        case .stats: "Stats"
        case .settings: "Settings"
        }
    }
}

struct PlayerRootView: View {
    @Environment(PlayerEnvironment.self) private var environment
    /// Bumped when the selected tab is tapped again: its screen starts over from the top.
    @State private var resets: [PlayerTab: Int] = [:]

    var body: some View {
        #if DEBUG
        if ProcessInfo.processInfo.environment["MPV_SMOKE"] != nil {
            MPVSmokeTest()
        } else {
            withSetup
        }
        #else
        withSetup
        #endif
    }

    private var withSetup: some View {
        content
            .firstLaunchSetup(common: environment.common, info: MiruSetup.info,
                              hasServer: { environment.common.serverAccounts[.jellyfin] != nil }) {
                MiruServerStep()
            } libraries: {
                MiruLibrariesStep()
            } extras: {
                MiruSetupExtras()
            } checklist: {
                MiruSetup.checklist(environment)
            }
    }

    @ViewBuilder private var content: some View {
        #if os(macOS)
        // A video covers the main window (sidebar included); the tabs stay underneath, so
        // closing returns to the same series page.
        ZStack {
            tabs
                // The Watch tab's toolbar would act on the hidden tabs.
                .toolbar(environment.playingSession == nil ? .automatic : .hidden, for: .windowToolbar)
            if let session = environment.playingSession {
                PlaybackContainer(session: session) { environment.playingSession = nil }
                    .id(session.id)
                    .background(.black)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: environment.playingSession?.id)
        #else
        tabs
        #endif
    }

    /// The selection, telling a tap on the tab already showing (start it over) from a switch.
    private var tabSelection: Binding<PlayerTab> {
        Binding {
            environment.selectedTab
        } set: { tab in
            if tab == environment.selectedTab { resets[tab, default: 0] += 1 }
            environment.selectedTab = tab
        }
    }

    private var tabs: some View {
        TabView(selection: tabSelection) {
            Tab(PlayerTab.watch.title, systemImage: "play.rectangle", value: .watch) {
                WatchView()
                    .id(resets[.watch])
            }
            Tab(PlayerTab.lines.title, systemImage: "text.quote", value: .lines) {
                // Tapped again: back to the list (not rebuilt with `.id`: on the iPhone Duo that
                // left the old back button in the side column).
                LinesView(reset: resets[.lines, default: 0])
            }
            Tab(PlayerTab.stats.title, systemImage: "chart.bar", value: .stats) {
                StatsView(kind: .watching, environment: environment.common) { series in
                    JellyfinImage(itemId: series.key, aspectRatio: 2 / 3, placeholder: "tv")
                }
                .id(resets[.stats])
            }
            Tab(PlayerTab.settings.title, systemImage: "gearshape", value: .settings) {
                PlayerSettingsView()
                    .id(resets[.settings])
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .tabViewSidebarFooter {
            SidebarLibraries(environment.libraries.filter { !environment.hiddenLibraries.contains($0.id) }, name: \.name,
                             systemImage: { $0.collectionType == "movies" ? "film" : "tv" }) { library in
                environment.openSeries(library)
            }
        }
    }
}

#Preview {
    let environment = PlayerEnvironment.preview()
    PlayerRootView().environment(environment).environment(environment.common)
}

#if DEBUG
/// Debug only (MPV_SMOKE=1, MPV_SMOKE_URL, MPV_SMOKE_AUTH): plays one stream to check mpv on this device.
private struct MPVSmokeTest: View {
    @State private var controller = MPVController()
    @State private var clipResult = ""

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            MPVVideoView(controller: controller).ignoresSafeArea()
            Text(String(format: "mpv %@ · %.1f s · %@ %@", MPVInfo.clientAPIVersion, controller.timePosition, controller.lastError ?? "ok", clipResult))
                .font(.caption.monospacedDigit())
                .padding(6)
                .background(.black.opacity(0.6))
                .foregroundStyle(.white)
                .accessibilityIdentifier("mpv.status")
        }
        .task {
            let env = ProcessInfo.processInfo.environment
            guard let url = env["MPV_SMOKE_URL"] else { return }
            let headers = env["MPV_SMOKE_AUTH"].map { ["Authorization": $0] } ?? [:]
            if env["MPV_CLIP"] != nil {
                // Card media only: 3 s of audio and one frame, without playing.
                let folder = URL.temporaryDirectory
                do {
                    let started = Date()
                    let audio = try await MediaClipper.audio(from: url, headers: headers, start: 60, end: 63, to: folder.appending(path: "clip.m4a"))
                    let frame = try await MediaClipper.frame(from: url, headers: headers, at: 61, to: folder.appending(path: "frame.jpg"))
                    let size = { (file: URL) in (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
                    clipResult = "clip \(size(audio)) B, frame \(size(frame)) B in \(String(format: "%.1f", Date().timeIntervalSince(started))) s at \(folder.path())"
                } catch {
                    clipResult = "clip error: \(error.localizedDescription)"
                }
            } else {
                controller.load(url, headers: headers)
            }
            controller.setPaused(false)
            // MPV_SMOKE_PAUSED=1: pause after a few seconds (rotation tests while paused).
            if env["MPV_SMOKE_PAUSED"] != nil {
                try? await Task.sleep(for: .seconds(3))
                controller.setPaused(true)
            }
        }
    }
}
#endif
