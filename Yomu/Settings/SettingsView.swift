import AppCommon
import Core
import OCR
import SwiftUI

/// Settings in the shape every app shares: status, Reading, Lookup
/// and Mining, Stats, then Storage, Advanced and About.
struct SettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var storageTotal: String?

    var body: some View {
        NavigationStack {
            Form {
                SettingsStatusCard(items: statusItems)

                Section {
                    NavigationLink(value: ServerKind.kavita) {
                        SettingsRowLabel("Kavita", subtitle: environment.serverAccounts[.kavita]?.hostAndAccount ?? "Not set up",
                                         systemImage: "server.rack", color: .indigo, dot: environment.serverAccounts[.kavita]?.dotColor)
                    }
                    .accessibilityIdentifier("settings.kavita")
                    NavigationLink {
                        LibrariesSettingsView()
                    } label: {
                        SettingsRowLabel("Libraries", value: librariesSummary, systemImage: "books.vertical.fill", color: .orange)
                    }
                    .accessibilityIdentifier("settings.libraries")
                    NavigationLink {
                        ReadingDownloadsView()
                    } label: {
                        SettingsRowLabel("Downloads", subtitle: "Automatic downloads, cellular, text read ahead",
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
                        SettingsRowLabel("Read-Along", subtitle: "Audiobookshelf and Kaku", systemImage: "headphones", color: .orange,
                                         dot: environment.serverAccounts[.audiobookshelf]?.dotColor)
                    }
                    .accessibilityIdentifier("settings.readAlong")
                } header: {
                    Text("Reading")
                } footer: {
                    Text("Read-Along plays a matching audiobook with the text. It's optional.")
                }

                LookupAndMiningSection(footnote: "Books only; manga pages aren\u{2019}t marked.") {
                    AnkiSettingsPage(environment: environment.common)
                }

                StatsSettingsLink()

                SettingsFooterSection(storageTotal: storageTotal) {
                    StorageView()
                } advanced: {
                    AdvancedSettingsView(kinds: [.ankiNote, .kavitaProgress, .audiobookshelfProgress],
                                         extraLogs: [URL.applicationSupportDirectory.appending(path: "dev-setup.log")]) {
                        LookupTimingsToggle()
                    }
                } about: {
                    AboutView(appCredits: [
                        ("nemu-ocr-coreml", "Apache-2.0", "Manga text detection and recognition models, downloaded in Settings."),
                    ])
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Settings")
            .navigationDestination(for: ServerKind.self) { kind in
                switch kind {
                case .kavita: KavitaSettingsView(environment: environment.common)
                case .anki: AnkiSettingsPage(environment: environment.common)
                case .audiobookshelf: AudiobookshelfSettingsView(environment: environment.common, tokens: environment.audiobookshelfTokens, appName: "Yomu")
                case .kaku: KakuSettingsView(environment: environment.common)
                case .jellyfin: EmptyView()
                }
            }
            .task { await measureStorage() }
        }
    }

    private var statusItems: [StatusItem] {
        let accounts = environment.serverAccounts
        return [
            StatusItem("Kavita", isSetUp: accounts[.kavita] != nil) {
                // Any user may ask who they are (server info is for admins).
                _ = try await environment.kavitaClient()?.currentUser()
            },
            StatusItem("Anki", isSetUp: accounts[.anki] != nil) {
                _ = try await environment.common.ankiClient()?.version()
            },
            StatusItem("Read-Along", isSetUp: accounts[.audiobookshelf] != nil) {
                _ = try await environment.audiobookshelfClient()?.me()
                if accounts[.kaku] != nil { _ = try await environment.kakuClient()?.health() }
            },
            StatusItem("kechimochi", isSetUp: (try? environment.common.activity.kechimochiURL()) ?? nil != nil) {
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

#Preview {
    let environment = AppEnvironment.preview()
    SettingsView().environment(environment).environment(environment.common)
}
