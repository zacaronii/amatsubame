import AppCommon
import KavitaKit
import SwiftUI

enum AppTab: String, Hashable, CaseIterable {
    case library, dictionary, stats, settings

    var title: String {
        switch self {
        // On the Mac the libraries have their own rows, so this is Home.
        #if os(macOS)
        case .library: "Home"
        #else
        case .library: "Library"
        #endif
        case .dictionary: "Dictionary"
        case .stats: "Stats"
        case .settings: "Settings"
        }
    }

    var systemImage: String {
        switch self {
        #if os(macOS)
        case .library: "house"
        #else
        case .library: "books.vertical"
        #endif
        case .dictionary: "character.book.closed.ja"
        case .stats: "chart.bar"
        case .settings: "gearshape"
        }
    }
}

/// A tab (wrapping `AppTab`, so the sidebar's extras could join later).
enum RootTab: Hashable {
    case app(AppTab)
}

struct RootView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var selection = RootTab.app(.library)
    /// Bumped when the selected tab is tapped again: its screen starts over from the top.
    @State private var resets: [RootTab: Int] = [:]
    /// The libraries in the sidebar (shown ones, readable; the Library tab keeps this cache fresh).
    @State private var sidebarLibraries: [KavitaLibrary] = []
    #if os(iOS)
    /// A volume opened from a link while no reader was showing.
    @State private var linkedSession: ReaderSession?
    #else
    @State private var destination = SidebarDestination<AppTab, Int>.tab(.library)
    @Environment(\.openWindow) private var openWindow
    #endif

    var body: some View {
        content
            .firstLaunchSetup(common: environment.common, info: YomuSetup.info,
                              hasServer: { environment.serverAccounts[.kavita] != nil }) {
                YomuServerStep()
            } libraries: {
                YomuLibrariesStep()
            } extras: {
                YomuSetupExtras()
            } checklist: {
                YomuSetup.checklist(environment)
            }
            .onOpenURL { environment.open($0) }
            .onChange(of: environment.requestedReader) { _, requested in
                // A reader in front takes the request itself (`ReaderContainer`).
                guard let requested, !environment.readerIsOpen else { return }
                environment.requestedReader = nil
                #if os(iOS)
                linkedSession = requested
                #else
                environment.readingSession = requested
                #endif
            }
            .alert("Can't Read Along", isPresented: Binding(get: { environment.linkProblem != nil },
                                                           set: { if !$0 { environment.linkProblem = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(environment.linkProblem ?? "")
            }
            #if os(iOS)
            .readerPresentation($linkedSession)
            #endif
    }

    @ViewBuilder private var content: some View {
        #if os(macOS)
        // Reading covers the main window (sidebar included); the tabs stay underneath so
        // closing returns to the same series page.
        ZStack {
            sidebar
                // The library's toolbar (back, title, menus) would act on the hidden tabs.
                .toolbar(environment.readingSession == nil ? .automatic : .hidden, for: .windowToolbar)
            if let session = environment.readingSession {
                ReaderContainer(session: session) { environment.readingSession = nil }
                    .background(.black)
                    .onKeyPress(.escape) {
                        NotificationCenter.default.post(name: .readerDidClose, object: nil)
                        environment.readingSession = nil
                        return .handled
                    }
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: environment.readingSession?.id)
        #else
        tabs
        #endif
    }

    #if os(macOS)
    /// The Mac's window: Home, Dictionary and Stats, pinned series, what's downloaded, and each library.
    private var sidebar: some View {
        MacSidebarSplit(
            selection: $destination,
            main: [AppTab.library, .dictionary, .stats].map { SidebarRow(.tab($0), title: $0.title, systemImage: $0.systemImage) },
            pinned: environment.common.pins.items,
            pinIcon: { $0.kind == "book" ? "book.closed" : "books.vertical" },
            unpin: { environment.common.pins.unpin($0.id) },
            downloaded: SidebarRow(.downloaded, title: "Downloaded", systemImage: "arrow.down.circle",
                                   count: environment.downloader.records.values.filter { $0.state == .done }.count),
            libraries: sidebarLibraries.map {
                SidebarRow(.library($0.id), title: $0.name, systemImage: $0.isBookLibrary ? "book.closed" : "books.vertical")
            }
        ) { destination in
            switch destination {
            case .tab(.dictionary): SearchView()
            case .tab(.stats): stats
            case .tab: LibraryView()
            case .pinned(let id):
                NavigationStack {
                    if let series = Int(id).flatMap({ try? environment.kavitaLibrary.cachedSeries(id: $0) }) {
                        SeriesDetailView(series: series)
                    } else {
                        ContentUnavailableView("Series Not Found", systemImage: "books.vertical",
                                               description: Text("Open its library to load it again."))
                    }
                }
            case .downloaded: NavigationStack { DownloadedVolumesView() }
            case .library(let id):
                if let library = sidebarLibraries.first(where: { $0.id == id }) {
                    NavigationStack {
                        SeriesGridView(library: library)
                            .navigationDestination(for: KavitaSeries.self) { SeriesDetailView(series: $0) }
                    }
                }
            }
        }
        .task(id: environment.hiddenLibraries) { loadSidebarLibraries() }
        .onReceive(NotificationCenter.default.publisher(for: .kavitaLibrariesDidChange)) { _ in loadSidebarLibraries() }
        // Menu shortcuts and links switch tabs; Settings is its own window.
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
        StatsView(kind: .reading, environment: environment.common) { series in
            CoverImage(request: Int(series.key).flatMap { environment.kavitaClient()?.seriesCoverRequest(seriesId: $0) })
        }
    }

    private var tabs: some View {
        TabView(selection: tabSelection) {
            Tab(AppTab.library.title, systemImage: AppTab.library.systemImage, value: RootTab.app(.library)) {
                LibraryView().id(resets[.app(.library)])
            }
            Tab(AppTab.dictionary.title, systemImage: AppTab.dictionary.systemImage, value: RootTab.app(.dictionary)) {
                SearchView().id(resets[.app(.dictionary)])
            }
            Tab(AppTab.stats.title, systemImage: AppTab.stats.systemImage, value: RootTab.app(.stats)) {
                stats.id(resets[.app(.stats)])
            }
            Tab(AppTab.settings.title, systemImage: AppTab.settings.systemImage, value: RootTab.app(.settings)) {
                SettingsView().id(resets[.app(.settings)])
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .tabViewSidebarFooter {
            SidebarLibraries(sidebarLibraries, name: \.name,
                             systemImage: { $0.isBookLibrary ? "book.closed" : "books.vertical" }) { library in
                environment.requestedLibrary = library
                selection = .app(.library)
                environment.selectedTab = .library
            }
        }
        .task(id: environment.hiddenLibraries) { loadSidebarLibraries() }
        .onReceive(NotificationCenter.default.publisher(for: .kavitaLibrariesDidChange)) { _ in loadSidebarLibraries() }
        .onChange(of: environment.selectedTab) { _, tab in
            if selection != .app(tab) { selection = .app(tab) }
        }
    }

    /// The selection, telling a tap on the tab already showing (start it over) from a switch.
    private var tabSelection: Binding<RootTab> {
        Binding {
            selection
        } set: { tab in
            if tab == selection { resets[tab, default: 0] += 1 }
            selection = tab
            if case .app(let appTab) = tab, environment.selectedTab != appTab { environment.selectedTab = appTab }
        }
    }

    private func loadSidebarLibraries() {
        sidebarLibraries = ((try? environment.kavitaLibrary.cachedLibraries()) ?? [])
            .filter { LibraryModel.readable($0) && !environment.hiddenLibraries.contains($0.id) }
    }
}

#Preview {
    let environment = AppEnvironment.preview()
    RootView().environment(environment).environment(environment.common)
}
