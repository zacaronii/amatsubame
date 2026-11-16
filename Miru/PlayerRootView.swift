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

    var systemImage: String {
        switch self {
        case .watch: "play.rectangle"
        case .lines: "text.quote"
        case .stats: "chart.bar"
        case .settings: "gearshape"
        }
    }
}

struct PlayerRootView: View {
    @Environment(PlayerEnvironment.self) private var environment
    /// Bumped when the selected tab is tapped again: its screen starts over from the top.
    @State private var resets: [PlayerTab: Int] = [:]
    #if os(macOS)
    @State private var destination = SidebarDestination<PlayerTab, String>.tab(.watch)
    @Environment(\.openSettings) private var openSettings
    #endif

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
            sidebar
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

    #if os(macOS)
    /// The Mac's window: Watch, Lines and Stats, what's downloaded, and each library.
    private var sidebar: some View {
        let libraries = environment.libraries.filter { !environment.hiddenLibraries.contains($0.id) }
        return MacSidebarSplit(
            selection: $destination,
            main: [PlayerTab.watch, .lines, .stats].map { SidebarRow(.tab($0), title: $0.title, systemImage: $0.systemImage) },
            downloaded: SidebarRow(.downloaded, title: "Downloaded", systemImage: "arrow.down.circle",
                                   count: environment.downloader.records.values.filter { $0.state == .done }.count),
            libraries: libraries.map {
                SidebarRow(.library($0.id), title: $0.name, systemImage: $0.collectionType == "movies" ? "film" : "tv")
            }
        ) { destination in
            switch destination {
            case .tab(.lines): LinesView()
            case .tab(.stats): stats
            case .tab: WatchView()
            case .downloaded: NavigationStack { DownloadedEpisodesView() }
            case .library(let id):
                if let library = libraries.first(where: { $0.id == id }) { LibraryStack(library: library) }
            }
        }
        // Menu shortcuts and links switch tabs; Settings is its own window.
        .onChange(of: environment.tabRequests) {
            let tab = environment.selectedTab
            if tab == .settings { openSettings() } else if destination != .tab(tab) { destination = .tab(tab) }
        }
        .onChange(of: destination) { _, destination in
            if case .tab(let tab) = destination, environment.selectedTab != tab { environment.selectedTab = tab }
        }
    }
    #endif

    private var stats: some View {
        StatsView(kind: .watching, environment: environment.common) { series in
            JellyfinImage(itemId: series.key, aspectRatio: 2 / 3, placeholder: "tv")
        }
    }

    private var tabs: some View {
        TabView(selection: tabSelection) {
            Tab(PlayerTab.watch.title, systemImage: PlayerTab.watch.systemImage, value: .watch) {
                WatchView()
                    .id(resets[.watch])
            }
            Tab(PlayerTab.lines.title, systemImage: PlayerTab.lines.systemImage, value: .lines) {
                // Tapped again: back to the list (not rebuilt with `.id`: on the iPhone Duo that
                // left the old back button in the side column).
                LinesView(reset: resets[.lines, default: 0])
            }
            Tab(PlayerTab.stats.title, systemImage: PlayerTab.stats.systemImage, value: .stats) {
                stats.id(resets[.stats])
            }
            Tab(PlayerTab.settings.title, systemImage: PlayerTab.settings.systemImage, value: .settings) {
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
