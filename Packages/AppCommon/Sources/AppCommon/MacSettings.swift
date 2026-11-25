#if os(macOS)
import Core
import SwiftUI

/// A page of the Mac's Settings window: a row in its sidebar and what it shows.
public struct MacSettingsPage: Identifiable {
    public let id: String
    let title: String
    let systemImage: String
    let content: () -> AnyView

    public init<Content: View>(_ id: String, title: String, systemImage: String, @ViewBuilder content: @escaping () -> Content) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.content = { AnyView(content()) }
    }
}

/// A group of pages under a heading (none for Overview and the last group).
public struct MacSettingsGroup: Identifiable {
    let title: String?
    let pages: [MacSettingsPage]
    public var id: String { title ?? pages.first?.id ?? "" }

    public init(_ title: String? = nil, pages: [MacSettingsPage]) {
        self.title = title
        self.pages = pages
    }
}

/// The Mac's Settings window (⌘,): a sidebar of pages like System Settings, each page in one
/// grouped form style at one width. iPhone and iPad keep Settings as a tab.
public struct MacSettingsWindow: View {
    /// The window's scene ID.
    public static let sceneID = "settings"
    /// The page width; wider windows centre it.
    static let pageWidth: CGFloat = 620

    let groups: [MacSettingsGroup]
    let serverPage: (ServerKind) -> AnyView
    @AppStorage("settings.page") private var selection = "overview"
    @State private var search = ""
    @State private var detailWidth: CGFloat = 0

    /// `serverPage`: what a link to a server opens (pages link to them by `ServerKind`).
    public init<Server: View>(groups: [MacSettingsGroup], @ViewBuilder serverPage: @escaping (ServerKind) -> Server) {
        self.groups = groups
        self.serverPage = { AnyView(serverPage($0)) }
    }

    public var body: some View {
        NavigationSplitView {
            List(selection: Binding<String?>(get: { selection }, set: { if let new = $0 { selection = new } })) {
                ForEach(shownGroups) { group in
                    if let title = group.title {
                        Section(title) { rows(group) }
                    } else {
                        Section { rows(group) }
                    }
                }
            }
            .searchable(text: $search, placement: .sidebar)
            .frame(minWidth: 230)
            // Wide enough for "Manga Text Recognition".
            .navigationSplitViewColumnWidth(230)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            NavigationStack {
                if let page {
                    page.content()
                        .navigationDestination(for: ServerKind.self, destination: serverPage)
                }
            }
            // On the stack, so the pages a page opens look the same.
            .formStyle(.grouped)
            .contentMargins(.horizontal, max(0, (detailWidth - Self.pageWidth) / 2), for: .scrollContent)
            .onGeometryChange(for: CGFloat.self, of: \.size.width) { detailWidth = $0 }
            // Each page starts at its top, not where another page's links had gone.
            .id(selection)
        }
        .frame(minWidth: 760, idealWidth: 860, minHeight: 480, idealHeight: 640)
        #if DEBUG
        .onAppear {
            if let page = ProcessInfo.processInfo.environment["UITEST_SETTINGS_PAGE"] { selection = page }
        }
        #endif
    }

    private var page: MacSettingsPage? {
        let pages = groups.flatMap(\.pages)
        return pages.first { $0.id == selection } ?? pages.first
    }

    /// The groups with only the pages whose titles match the search.
    private var shownGroups: [MacSettingsGroup] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return groups }
        return groups.compactMap { group in
            let pages = group.pages.filter { $0.title.localizedCaseInsensitiveContains(query) }
            return pages.isEmpty ? nil : MacSettingsGroup(group.title, pages: pages)
        }
    }

    private func rows(_ group: MacSettingsGroup) -> some View {
        ForEach(group.pages) { page in
            Label(page.title, systemImage: page.systemImage)
                .tag(page.id)
                .accessibilityIdentifier("settings.page.\(page.id)")
        }
    }
}

public extension MacSettingsPage {
    /// Overview: the status card.
    static func overview(_ items: [StatusItem]) -> MacSettingsPage {
        MacSettingsPage("overview", title: "Overview", systemImage: "gearshape") {
            Form { SettingsStatusCard(items: items) }
                .navigationTitle("Overview")
        }
    }

    /// Lookup and Mining's pages, the same in every app. `anki`: the app's Anki page.
    static func lookupAndMining<Anki: View>(@ViewBuilder anki: @escaping () -> Anki) -> [MacSettingsPage] {
        [
            MacSettingsPage("dictionaries", title: "Dictionaries", systemImage: "character.book.closed.ja") { DictionariesView() },
            MacSettingsPage("audioSources", title: "Audio Sources", systemImage: "speaker.wave.2") { AudioSourcesView() },
            MacSettingsPage("popup", title: "Popup", systemImage: "text.bubble") { PopupSettingsPage() },
            MacSettingsPage("anki", title: "Anki", systemImage: "rectangle.stack") { anki() },
        ]
    }

    /// Stats: the same on every device, through iCloud.
    static var statsCloud: MacSettingsPage {
        MacSettingsPage("statsCloud", title: "Sync with iCloud", systemImage: "icloud") {
            Form {
                Section {
                    StatsCloudRow()
                } footer: {
                    Text("Keeps this app's Stats, goals and settings the same on your devices signed in to the same iCloud account.")
                }
            }
            .navigationTitle("Sync with iCloud")
        }
    }

    /// Stats: kechimochi.
    static var kechimochi: MacSettingsPage {
        MacSettingsPage("kechimochi", title: "kechimochi", systemImage: "chart.bar") {
            Form { StatsSettingsSection() }
                .navigationTitle("kechimochi")
        }
    }
}

public extension MacSettingsGroup {
    /// Lookup and Mining, then Connections (the app's `servers` first): the groups every app
    /// has after its own.
    static func shared<Anki: View>(servers: [MacSettingsPage], @ViewBuilder anki: @escaping () -> Anki) -> [MacSettingsGroup] {
        [
            MacSettingsGroup("Lookup and Mining", pages: MacSettingsPage.lookupAndMining(anki: anki)),
            MacSettingsGroup("Connections", pages: servers + [
                MacSettingsPage("hachidori", title: "Hachidori", systemImage: "bird") { HachidoriSettingsPage() },
                .kechimochi, .statsCloud,
            ]),
        ]
    }

    /// The last group: Storage, Advanced and About.
    static func footer<Storage: View, Advanced: View, About: View>(
        @ViewBuilder storage: @escaping () -> Storage, @ViewBuilder advanced: @escaping () -> Advanced,
        @ViewBuilder about: @escaping () -> About
    ) -> MacSettingsGroup {
        MacSettingsGroup(pages: [
            MacSettingsPage("storage", title: "Storage", systemImage: "internaldrive", content: storage),
            MacSettingsPage("advanced", title: "Advanced", systemImage: "wrench.and.screwdriver", content: advanced),
            MacSettingsPage("about", title: "About", systemImage: "info.circle", content: about),
        ])
    }
}

/// Settings… (⌘,) in the app menu, opening the Settings window.
public struct MacSettingsCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    public init() {}

    public var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { openWindow(id: MacSettingsWindow.sceneID) }
                .keyboardShortcut(",")
        }
    }
}

public extension View {
    /// UI tests: opens Settings at launch, at `UITEST_SETTINGS_PAGE`.
    func opensSettingsForUITests() -> some View {
        #if DEBUG
        modifier(OpensSettings())
        #else
        self
        #endif
    }
}

#if DEBUG
private struct OpensSettings: ViewModifier {
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.task {
            if ProcessInfo.processInfo.environment["UITEST_SETTINGS_PAGE"] != nil { openWindow(id: MacSettingsWindow.sceneID) }
        }
    }
}
#endif

#endif
