import AppCommon
import Core
import OCR
import SwiftUI

/// Settings in the shape every app shares: status, Reading, Lookup, Anki, Connections, then
/// Storage, Advanced and About.
struct SettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var storageTotal: String?

    var body: some View {
        NavigationStack {
            Form {
                SettingsStatusCard(items: statusItems)

                Section {
                    NavigationLink {
                        LibrariesSettingsView()
                    } label: {
                        SettingsRowLabel("Libraries", value: librariesSummary, systemImage: "books.vertical.fill", color: .orange)
                    }
                    .accessibilityIdentifier("settings.libraries")
                    NavigationLink {
                        ReadingDownloadsView()
                    } label: {
                        SettingsRowLabel("Download Rules", subtitle: "Automatic, over cellular, text read ahead",
                                         systemImage: "arrow.down.circle.fill", color: .blue)
                    }
                    .accessibilityIdentifier("settings.downloads")
                    NavigationLink {
                        OCRSettingsView()
                    } label: {
                        SettingsRowLabel("Manga Text Recognition", subtitle: ocrSummary, systemImage: "text.viewfinder", color: .cyan)
                    }
                    .accessibilityIdentifier("settings.ocr")
                    NavigationLink {
                        ReadAlongSettingsView()
                    } label: {
                        SettingsRowLabel("Read-Along", subtitle: readAlongSummary,
                                         systemImage: "headphones", color: .orange,
                                         dot: environment.serverAccounts[.audiobookshelf]?.dotColor)
                    }
                    .accessibilityIdentifier("settings.readAlong")
                } header: {
                    Text("Reading")
                }

                LookupSection(wordMarksNote: Self.wordMarksNote, popupExtras: AnyView(LookupTimingsToggle()))

                AnkiSection {
                    Self.anki(environment)
                }

                ConnectionsSection {
                    NavigationLink(value: ServerKind.kavita) {
                        SettingsRowLabel("Kavita", subtitle: environment.serverAccounts[.kavita]?.hostAndAccount ?? "Not set up",
                                         systemImage: "server.rack", color: .indigo, dot: environment.serverAccounts[.kavita]?.dotColor)
                    }
                    .accessibilityIdentifier("settings.kavita")
                    NavigationLink(value: ServerKind.audiobookshelf) {
                        SettingsRowLabel("Audiobookshelf", subtitle: environment.serverAccounts[.audiobookshelf]?.hostAndAccount ?? "Optional · for read-along",
                                         systemImage: "headphones", color: .orange, dot: environment.serverAccounts[.audiobookshelf]?.dotColor)
                    }
                    .accessibilityIdentifier("settings.audiobookshelf")
                    NavigationLink(value: ServerKind.kaku) {
                        KakuSettingsRow()
                    }
                    .accessibilityIdentifier("settings.kaku")
                }

                SettingsFooterSection(storageTotal: storageTotal) {
                    StorageView()
                } advanced: {
                    Self.advanced
                } about: {
                    Self.about
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Settings")
            .navigationDestination(for: ServerKind.self) { Self.serverPage($0, environment: environment) }
            .task { await measureStorage() }
        }
    }

    static var advanced: some View {
        AdvancedSettingsView(kinds: [.ankiNote, .kavitaProgress, .audiobookshelfProgress, .audiobookshelfSession],
                             extraLogs: [URL.applicationSupportDirectory.appending(path: "dev-setup.log")]) {
            LibraryDataSection()
        }
    }

    static let credits = [
        ("nemu-ocr-coreml", "Apache-2.0", "Manga text detection and recognition models, downloaded in Settings."),
    ]

    static var about: some View {
        AboutView(appCredits: credits)
    }

    static func anki(_ environment: AppEnvironment) -> some View {
        AnkiSettingsPage(environment: environment.common)
    }

    /// Word marks are drawn in books only.
    static let wordMarksNote = "Books only; manga pages aren\u{2019}t marked."

    /// What a link to a server opens.
    @ViewBuilder static func serverPage(_ kind: ServerKind, environment: AppEnvironment) -> some View {
        switch kind {
        case .kavita: KavitaSettingsView(environment: environment.common)
        case .anki: anki(environment)
        case .audiobookshelf: AudiobookshelfSettingsView(environment: environment.common, tokens: environment.audiobookshelfTokens, appName: "Yomu")
        case .kaku: KakuSettingsView(environment: environment.common)
        case .jellyfin: EmptyView()
        }
    }

    /// Read-Along needs both: Audiobookshelf for the audiobook, Kaku for its transcript.
    private var readAlongSummary: String {
        switch (environment.serverAccounts[.audiobookshelf] != nil, environment.serverAccounts[.kaku] != nil) {
        case (false, false): "Optional"
        case (true, false): "Needs Kaku"
        case (false, true): "Needs Audiobookshelf"
        case (true, true): "Ready"
        }
    }

    private var statusItems: [StatusItem] { Self.statusItems(environment) }

    static func statusItems(_ environment: AppEnvironment) -> [StatusItem] {
        let accounts = environment.serverAccounts
        return [
            StatusItem("Kavita", isSetUp: accounts[.kavita] != nil, opens: { AnyView(serverPage(.kavita, environment: environment)) }) {
                // Any user may ask who they are (server info is for admins).
                _ = try await environment.kavitaClient()?.currentUser()
            },
            StatusItem("Anki", isSetUp: accounts[.anki] != nil, opens: { AnyView(serverPage(.anki, environment: environment)) }) {
                _ = try await environment.common.ankiClient()?.version()
            },
            StatusItem("Read-Along", isSetUp: accounts[.audiobookshelf] != nil, opens: { AnyView(ReadAlongSettingsView()) }) {
                _ = try await environment.audiobookshelfClient()?.me()
                if accounts[.kaku] != nil { _ = try await environment.kakuClient()?.health() }
            },
            StatusItem("kechimochi", isSetUp: (try? environment.common.activity.kechimochiURL()) ?? nil != nil, opens: { AnyView(KechimochiPage()) }) {
                try await environment.common.checkKechimochi()
            },
        ]
    }

    private var librariesSummary: String? {
        let libraries = ((try? environment.kavitaLibrary.cachedLibraries()) ?? []).filter(LibraryModel.readable)
        guard !libraries.isEmpty else { return nil }
        let shown = libraries.filter { !environment.hiddenLibraries.contains($0.id) }.count
        return "\(shown) of \(libraries.count)"
    }

    private var ocrSummary: String {
        switch environment.ocrModels.state {
        case .installed: "Models installed"
        case .downloading: "Downloading…"
        case .compiling: "Preparing…"
        case .failed: "Download failed"
        case .notInstalled: "Not downloaded"
        }
    }

    private func measureStorage() async {
        let downloads = environment.downloader.records.values.reduce(Int64(0)) { $0 + ($1.state == .done ? ($1.bytesTotal ?? 0) : $1.bytesDone) }
        let cache = Int64(await environment.books.unpinnedBytes() + ((try? environment.pageCache.unpinnedBytes()) ?? 0))
        let models: Int64 = environment.ocrModels.state == .installed ? Int64(OCRModelStore.totalBytes) : 0
        storageTotal = (downloads + cache + models + environment.common.dictionaries.totalBytes()).storageText
    }
}

#if os(macOS)
/// The Mac's Settings window: the same pages as the list above, each in the sidebar.
struct MacSettingsView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        MacSettingsWindow(groups: [
            MacSettingsGroup(pages: [.overview(SettingsView.statusItems(environment))]),
            MacSettingsGroup("Reading", pages: [
                MacSettingsPage("libraries", title: "Libraries", systemImage: "books.vertical") { LibrariesSettingsView() },
                MacSettingsPage("downloads", title: "Download Rules", systemImage: "arrow.down.circle",
                                keywords: ["Automatic Downloads", "Read Text on Downloaded Pages"]) { ReadingDownloadsView() },
                MacSettingsPage("ocr", title: "Manga Text Recognition", systemImage: "text.viewfinder",
                                keywords: ["OCR", "Models"]) { OCRSettingsView() },
                MacSettingsPage("readAlong", title: "Read-Along", systemImage: "headphones",
                                keywords: ["Audiobook"]) { ReadAlongSettingsView() },
            ]),
        ] + MacSettingsGroup.shared(wordMarksNote: SettingsView.wordMarksNote, popupExtras: AnyView(LookupTimingsToggle()), servers: [
            MacSettingsPage("kavita", title: "Kavita", systemImage: "server.rack") { KavitaSettingsView(environment: environment.common) },
            MacSettingsPage("audiobookshelf", title: "Audiobookshelf", systemImage: "headphones") {
                AudiobookshelfSettingsView(environment: environment.common, tokens: environment.audiobookshelfTokens, appName: "Yomu")
            },
            MacSettingsPage("kaku", title: "Kaku", systemImage: "text.quote") { KakuSettingsView(environment: environment.common) },
        ]) {
            SettingsView.anki(environment)
        } + [
            .footer(storageKeywords: ["Read-Along Audio", "Text Recognition Models", "Cache"],
                    advancedKeywords: ["Character Counts"]) {
                StorageView()
            } advanced: {
                SettingsView.advanced
            } about: {
                SettingsView.about
            },
        ]) { kind in
            SettingsView.serverPage(kind, environment: environment)
        }
    }
}
#endif

#Preview {
    let environment = AppEnvironment.preview()
    SettingsView().environment(environment).environment(environment.common)
}
