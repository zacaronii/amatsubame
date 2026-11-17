import AppCommon
import SwiftUI

enum KikuTab: Hashable, CaseIterable {
    case listen, marks, stats, settings

    var title: String {
        switch self {
        case .listen: "Listen"
        case .marks: "Marks"
        case .stats: "Stats"
        case .settings: "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .listen: "headphones"
        case .marks: "bookmark"
        case .stats: "chart.bar"
        case .settings: "gearshape"
        }
    }
}

struct KikuRootView: View {
    @Environment(KikuEnvironment.self) private var environment
    /// Bumped when the selected tab is tapped again: its screen starts over from the top.
    @State private var resets: [KikuTab: Int] = [:]
    #if os(macOS)
    @State private var destination = SidebarDestination<KikuTab, String>.tab(.listen)
    @Environment(\.openWindow) private var openWindow
    #endif

    var body: some View {
        main
            .firstLaunchSetup(common: environment.common, info: KikuSetup.info,
                              hasServer: { environment.common.serverAccounts[.audiobookshelf] != nil }) {
                KikuServerStep()
            } libraries: {
                KikuLibrariesStep()
            } extras: {
                KikuSetupExtras()
            } checklist: {
                KikuSetup.checklist(environment)
            }
    }

    @ViewBuilder private var main: some View {
        @Bindable var environment = environment
        #if os(macOS)
        // The player covers the main window; the tabs stay underneath. The mini player is a bar
        // at the bottom (the tab bar accessory is iPhone and iPad only).
        ZStack {
            sidebar
                .safeAreaInset(edge: .bottom) {
                    if let playback = environment.playback, !environment.showsPlayer {
                        MiniPlayer(model: playback)
                            .padding(.vertical, 8)
                            .glassEffect(.regular, in: .capsule)
                            .padding(.horizontal)
                            .padding(.bottom, 8)
                    }
                }
            if environment.showsPlayer, let playback = environment.playback {
                PlayerView(model: playback)
                    .transition(.move(edge: .bottom))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: environment.showsPlayer)
        #else
        tabs
            .modifier(MiniPlayerAccessory(playback: environment.playback))
            .fullScreenCover(isPresented: Binding(get: { environment.showsPlayer && environment.playback != nil },
                                                  set: { environment.showsPlayer = $0 })) {
                if let playback = environment.playback { PlayerView(model: playback) }
            }
        #endif
    }

    /// The selection, telling a tap on the tab already showing (start it over) from a switch.
    private var tabSelection: Binding<KikuTab> {
        Binding {
            environment.selectedTab
        } set: { tab in
            if tab == environment.selectedTab { resets[tab, default: 0] += 1 }
            environment.selectedTab = tab
        }
    }

    #if os(macOS)
    /// The Mac's window: Listen, Marks and Stats, what's downloaded, and each library.
    private var sidebar: some View {
        let hidden = environment.library.hiddenLibraries
        let libraries = environment.library.libraries.filter { !hidden.contains($0.id) }
        return MacSidebarSplit(
            selection: $destination,
            main: [KikuTab.listen, .marks, .stats].map { SidebarRow(.tab($0), title: $0.title, systemImage: $0.systemImage) },
            pinned: environment.common.pins.items,
            pinIcon: { $0.kind == "book" ? "book.closed" : "dot.radiowaves.left.and.right" },
            unpin: { environment.common.pins.unpin($0.id) },
            downloaded: SidebarRow(.downloaded, title: "Downloaded", systemImage: "arrow.down.circle",
                                   count: environment.downloader.records.values.filter { $0.state == .done }.count),
            libraries: libraries.map {
                SidebarRow(.library($0.id), title: $0.name, systemImage: $0.mediaType == .book ? "book.closed" : "dot.radiowaves.left.and.right")
            }
        ) { destination in
            switch destination {
            case .tab(.marks): MarksView()
            case .tab(.stats): stats
            case .tab: ListenView()
            case .pinned(let id):
                if let pin = environment.common.pins.items.first(where: { $0.id == id }) {
                    NavigationStack {
                        ListenDestination(route: pin.kind == "book" ? .book(pin.id) : .show(pin.id))
                            .navigationDestination(for: ListenRoute.self) { ListenDestination(route: $0) }
                    }
                }
            case .downloaded: NavigationStack { DownloadedEpisodesView() }
            case .library(let id):
                if let library = libraries.first(where: { $0.id == id }) {
                    NavigationStack {
                        LibraryView(only: library)
                            .navigationDestination(for: ListenRoute.self) { ListenDestination(route: $0) }
                    }
                }
            }
        }
        .yomuMissingAlert(environment, inPlayer: false)
        // Menu shortcuts and buttons switch tabs; Settings is its own window.
        .opensSettingsForUITests()
        .onChange(of: environment.tabRequests) {
            let tab = environment.selectedTab
            if tab == .settings { openWindow(id: MacSettingsWindow.sceneID) } else if destination != .tab(tab) { destination = .tab(tab) }
        }
        .onChange(of: destination) { _, destination in
            if case .tab(let tab) = destination, environment.selectedTab != tab { environment.selectedTab = tab }
        }
    }
    #endif

    private var stats: some View {
        StatsView(kind: .listening, environment: environment.common) { series in
            ShowCover(itemId: series.key)
        }
    }

    private var tabs: some View {
        TabView(selection: tabSelection) {
            Tab(KikuTab.listen.title, systemImage: KikuTab.listen.systemImage, value: .listen) {
                // Tapped again: back to the home screen. Not rebuilt with `.id` like the other
                // tabs: on the iPhone Duo that left the old back button in the side column.
                ListenView(reset: resets[.listen, default: 0])
                    .clearOfBottomAccessory(environment.playback != nil)
            }
            Tab(KikuTab.marks.title, systemImage: KikuTab.marks.systemImage, value: .marks) {
                MarksView()
                    .clearOfBottomAccessory(environment.playback != nil)
                    .id(resets[.marks])
            }
            Tab(KikuTab.stats.title, systemImage: KikuTab.stats.systemImage, value: .stats) {
                stats
                .clearOfBottomAccessory(environment.playback != nil)
                .id(resets[.stats])
            }
            Tab(KikuTab.settings.title, systemImage: KikuTab.settings.systemImage, value: .settings) {
                KikuSettingsView()
                    .clearOfBottomAccessory(environment.playback != nil)
                    .id(resets[.settings])
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .tabViewSidebarFooter {
            let hidden = environment.library.hiddenLibraries
            SidebarLibraries(environment.library.libraries.filter { !hidden.contains($0.id) }, name: \.name,
                             systemImage: { $0.mediaType == .book ? "book.closed" : "dot.radiowaves.left.and.right" }) { library in
                environment.requestedLibrary = library
                environment.selectedTab = .listen
            }
        }
        .yomuMissingAlert(environment, inPlayer: false)
    }
}

#if os(iOS)
/// The system mini player above the tab bar, shown while an episode is loaded.
private struct MiniPlayerAccessory: ViewModifier {
    let playback: PlaybackModel?

    func body(content: Content) -> some View {
        if #available(iOS 26.1, *) {
            content.tabViewBottomAccessory(isEnabled: playback != nil) {
                if let playback { MiniPlayer(model: playback) }
            }
        } else {
            content.tabViewBottomAccessory {
                if let playback { MiniPlayer(model: playback) } else { Text("Not playing").foregroundStyle(.secondary) }
            }
        }
    }
}
#endif

#Preview {
    let environment = KikuEnvironment.preview()
    KikuRootView().environment(environment).environment(environment.common)
}
