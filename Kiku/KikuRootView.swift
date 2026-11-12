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
}

struct KikuRootView: View {
    @Environment(KikuEnvironment.self) private var environment
    /// Bumped when the selected tab is tapped again: its screen starts over from the top.
    @State private var resets: [KikuTab: Int] = [:]

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
            tabs
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

    private var tabs: some View {
        TabView(selection: tabSelection) {
            Tab(KikuTab.listen.title, systemImage: "headphones", value: .listen) {
                // Tapped again: back to the home screen. Not rebuilt with `.id` like the other
                // tabs: on the iPhone Duo that left the old back button in the side column.
                ListenView(reset: resets[.listen, default: 0])
                    .clearOfBottomAccessory(environment.playback != nil)
            }
            Tab(KikuTab.marks.title, systemImage: "bookmark", value: .marks) {
                MarksView()
                    .clearOfBottomAccessory(environment.playback != nil)
                    .id(resets[.marks])
            }
            Tab(KikuTab.stats.title, systemImage: "chart.bar", value: .stats) {
                StatsView(kind: .listening, environment: environment.common) { series in
                    ShowCover(itemId: series.key)
                }
                .clearOfBottomAccessory(environment.playback != nil)
                .id(resets[.stats])
            }
            Tab(KikuTab.settings.title, systemImage: "gearshape", value: .settings) {
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
