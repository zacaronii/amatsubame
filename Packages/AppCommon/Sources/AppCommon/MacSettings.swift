#if os(macOS)
import Core
import SwiftUI

/// A page of the Mac's Settings window: a row in its sidebar and what it shows. `keywords`:
/// the page's row titles, so the sidebar's search finds the page by them too. They're kept by
/// hand: renaming, adding or moving a row means updating them (docs/shared.md).
public struct MacSettingsPage: Identifiable {
    public let id: String
    let title: String
    let systemImage: String
    let keywords: [String]
    let content: () -> AnyView

    public init<Content: View>(_ id: String, title: String, systemImage: String, keywords: [String] = [],
                               @ViewBuilder content: @escaping () -> Content) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.keywords = keywords
        self.content = { AnyView(content()) }
    }

    func matches(_ query: String) -> Bool {
        ([title] + keywords).contains { $0.localizedCaseInsensitiveContains(query) }
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

    private var shownGroups: [MacSettingsGroup] { Self.filter(groups, search: search) }

    /// The groups with only the pages whose title or row titles match the search.
    static func filter(_ groups: [MacSettingsGroup], search: String) -> [MacSettingsGroup] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return groups }
        return groups.compactMap { group in
            let pages = group.pages.filter { $0.matches(query) }
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

    /// Lookup's pages, the same in every app.
    static func lookup(wordMarksNote: String?, popupExtras: AnyView?) -> [MacSettingsPage] {
        [
            MacSettingsPage("dictionaries", title: "Dictionaries", systemImage: "character.book.closed.ja",
                            keywords: ["Sort Results By", "Frequency", "Add Recommended", "Import from Files", "Import from URL",
                                       "Copy from Hachidori"]) { DictionariesView() },
            MacSettingsPage("popup", title: "Popup", systemImage: "text.bubble",
                            keywords: ["Snippets", "Summary Dictionary", "Background Opacity", "Look Up on Hover",
                                       "Close When the Pointer Leaves", "Lookup Counts"]) { PopupSettingsPage(extras: popupExtras) },
            MacSettingsPage("audioSources", title: "Audio Sources", systemImage: "speaker.wave.2",
                            keywords: ["Word Audio", "Add Source"]) { AudioSourcesView() },
            MacSettingsPage("wordMarks", title: "Word Marks", systemImage: "underline",
                            keywords: ["Known and Ignored Words", "Also Mark Words From"]) { WordMarksPage(note: wordMarksNote) },
        ]
    }

    /// Stats: the same on every device, through iCloud.
    static var statsCloud: MacSettingsPage {
        MacSettingsPage("statsCloud", title: "Sync with iCloud", systemImage: "icloud", keywords: ["Stats"]) {
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
        MacSettingsPage("kechimochi", title: "kechimochi", systemImage: "chart.bar", keywords: ["Stats"]) { KechimochiPage() }
    }
}

public extension MacSettingsGroup {
    /// Lookup, Anki, then Connections (the app's `servers` first): the groups every app has
    /// after its own. `wordMarksNote` and `popupExtras` as in `LookupSection`.
    static func shared<Anki: View>(wordMarksNote: String? = nil, popupExtras: AnyView? = nil, servers: [MacSettingsPage],
                                   @ViewBuilder anki: @escaping () -> Anki) -> [MacSettingsGroup] {
        [
            MacSettingsGroup("Lookup", pages: MacSettingsPage.lookup(wordMarksNote: wordMarksNote, popupExtras: popupExtras)),
            MacSettingsGroup("Anki", pages: [
                MacSettingsPage("anki", title: "Anki", systemImage: "rectangle.stack",
                                keywords: ["AnkiConnect", "Deck", "Note Type", "Fields", "Sync After Adding", "Sync Anki Collection"]) { anki() },
            ]),
            MacSettingsGroup("Connections", pages: servers + [
                MacSettingsPage("hachidori", title: "Hachidori", systemImage: "bird",
                                keywords: ["Use Hachidori", "Link", "Test Connection", "Last Synced", "Waiting to Send"]) { HachidoriSettingsPage() },
                .kechimochi, .statsCloud,
            ]),
        ]
    }

    /// The last group: Storage, Advanced and About. `storageKeywords`, `advancedKeywords`: the
    /// app's own rows on those pages, for the search.
    static func footer<Storage: View, Advanced: View, About: View>(
        storageKeywords: [String] = [], advancedKeywords: [String] = [],
        @ViewBuilder storage: @escaping () -> Storage, @ViewBuilder advanced: @escaping () -> Advanced,
        @ViewBuilder about: @escaping () -> About
    ) -> MacSettingsGroup {
        MacSettingsGroup(pages: [
            MacSettingsPage("storage", title: "Storage", systemImage: "internaldrive",
                            keywords: ["Downloaded", "Dictionaries"] + storageKeywords, content: storage),
            MacSettingsPage("advanced", title: "Advanced", systemImage: "wrench.and.screwdriver",
                            keywords: ["Share Setup", "Waiting to Sync", "Run Setup Again", "Export Logs"] + advancedKeywords,
                            content: advanced),
            MacSettingsPage("about", title: "About", systemImage: "info.circle",
                            keywords: ["Version", "Report a Bug", "Suggest an Idea", "Feedback", "Open Source", "Recommended Dictionaries"],
                            content: about),
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
