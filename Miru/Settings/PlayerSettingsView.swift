import AppCommon
import PlayerKit
import Core
import SwiftUI

struct PlayerSettingsView: View {
    @Environment(PlayerEnvironment.self) private var environment

    /// The cheat sheet is for a keyboard: the Mac, and an iPad (which may have one attached).
    private var showsKeyboardShortcuts: Bool {
        #if os(macOS)
        true
        #else
        UIDevice.current.userInterfaceIdiom == .pad || ProcessInfo.processInfo.environment["UITEST_PLAYER"] != nil
        #endif
    }

    /// mpv and FFmpeg come from MPVKit's LGPL build, linked as frameworks.
    static let credits: [(String, String, String)] = [
        ("mpv", "LGPL-2.1+", "Video playback (LGPL build, via MPVKit; client API \(MPVInfo.clientAPIVersion))."),
        ("FFmpeg", "LGPL-2.1+", "Demuxing and decoding, and the audio clips and screenshots on cards."),
        ("MPVKit", "LGPL-3.0", "mpv and FFmpeg packaged for Apple platforms."),
        ("MoltenVK", "Apache-2.0", "Vulkan on Metal, used by mpv's renderer."),
        ("libfvad", "BSD-3-Clause", "Speech detection for subtitle sync (WebRTC's voice activity detector)."),
        ("Mozilla CA certificates", "MPL-2.0", "The certificate list mpv uses for HTTPS."),
    ]

    var body: some View {
        NavigationStack {
            Form {
                SettingsStatusCard(items: statusItems)

                Section {
                    NavigationLink(value: ServerKind.jellyfin) {
                        SettingsRowLabel("Jellyfin", subtitle: accounts[.jellyfin]?.hostAndAccount ?? "Not set up",
                                         systemImage: "server.rack", color: .indigo, dot: accounts[.jellyfin]?.dotColor)
                    }
                    .accessibilityIdentifier("settings.jellyfin")
                    NavigationLink {
                        JellyfinLibrariesSettingsView()
                    } label: {
                        SettingsRowLabel("Libraries", value: librariesSummary, systemImage: "books.vertical.fill", color: .orange)
                    }
                    .accessibilityIdentifier("settings.libraries")
                    NavigationLink {
                        SubtitlesSettingsView()
                    } label: {
                        SettingsRowLabel("Subtitles", subtitle: subtitlesSummary, systemImage: "captions.bubble.fill", color: .indigo)
                    }
                    .accessibilityIdentifier("settings.subtitles")
                    NavigationLink {
                        PlaybackSettingsView()
                    } label: {
                        SettingsRowLabel("Playback", subtitle: "Skip intros, Japanese audio only", systemImage: "play.rectangle.fill", color: .red)
                    }
                    .accessibilityIdentifier("settings.playback")
                    NavigationLink {
                        Form { DownloadSettingsSection { _ in } }
                            .formStyle(.grouped)
                            .navigationTitle("Downloads")
                    } label: {
                        SettingsRowLabel("Downloads", subtitle: "Wi-Fi or cellular", systemImage: "arrow.down.circle.fill", color: .blue)
                    }
                    .accessibilityIdentifier("settings.downloads")
                    if showsKeyboardShortcuts {
                        NavigationLink {
                            PlayerShortcutsView()
                        } label: {
                            SettingsRowLabel("Keyboard Shortcuts", systemImage: "keyboard.fill", color: .gray)
                        }
                        .accessibilityIdentifier("settings.shortcuts")
                    }
                } header: {
                    Text("Watching")
                }

                LookupAndMiningSection {
                    AnkiSettingsPage(environment: environment.common) {
                        CardPicturePicker()
                    }
                }

                StatsSettingsLink()

                SettingsFooterSection(storageTotal: storageTotal) {
                    StorageView()
                } advanced: {
                    AdvancedSettingsView(kinds: [.ankiNote, .jellyfinProgress, .jellyfinSubtitle],
                                         extraLogs: ["dev-setup.log", "nowplaying.log"].map { URL.applicationSupportDirectory.appending(path: $0) })
                } about: {
                    AboutView(appCredits: Self.credits)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Settings")
            .navigationDestination(for: ServerKind.self) { kind in
                switch kind {
                case .jellyfin: JellyfinSettingsView(environment: environment.common)
                case .anki: AnkiSettingsPage(environment: environment.common) { CardPicturePicker() }
                case .kaku: KakuSettingsView(environment: environment.common)
                case .kavita, .audiobookshelf: EmptyView()
                }
            }
            .task { measureStorage() }
            .task(id: accounts[.jellyfin]?.baseURL) {
                libraryIDs = try? await environment.jellyfinClient()?.views().map(\.id)
            }
        }
    }

    @State private var storageTotal: String?
    /// The server's libraries, for the "1 of 2" count (nil until loaded).
    @State private var libraryIDs: [String]?

    private var librariesSummary: String? {
        guard let libraryIDs, !libraryIDs.isEmpty else { return nil }
        return "\(libraryIDs.filter { !environment.hiddenLibraries.contains($0) }.count) of \(libraryIDs.count)"
    }

    private var subtitlesSummary: String {
        let jimaku = ((try? environment.common.secrets.secret(for: .jimakuAPIKey)) ?? nil) != nil
        let sources = [jimaku ? "Jimaku" : nil, accounts[.kaku] != nil ? "Kaku" : nil].compactMap { $0 }
        return sources.isEmpty ? "Not set up" : sources.joined(separator: " · ")
    }

    private var accounts: [ServerKind: ServerAccount] { environment.common.serverAccounts }

    private var statusItems: [StatusItem] {
        [
            StatusItem("Jellyfin", isSetUp: accounts[.jellyfin] != nil) {
                _ = try await environment.jellyfinClient()?.currentUser()
            },
            StatusItem("Anki", isSetUp: accounts[.anki] != nil) {
                _ = try await environment.common.ankiClient()?.version()
            },
            StatusItem("Jimaku", isSetUp: ((try? environment.common.secrets.secret(for: .jimakuAPIKey)) ?? nil) != nil) {
                _ = try await environment.jimakuClient()?.search(query: "テスト")
            },
            StatusItem("Kaku", isSetUp: accounts[.kaku] != nil) {
                _ = try await environment.kakuClient()?.health()
            },
            StatusItem("kechimochi", isSetUp: ((try? environment.common.activity.kechimochiURL()) ?? nil) != nil) {
                try await environment.common.checkKechimochi()
            },
        ]
    }

    private func measureStorage() {
        let downloads = environment.downloader.records.values.reduce(Int64(0)) { $0 + ($1.state == .done ? ($1.bytesTotal ?? 0) : $1.bytesDone) }
        let subtitles = Int64((try? environment.transcripts.approximateBytes()) ?? 0)
        storageTotal = (downloads + subtitles + environment.common.dictionaries.totalBytes()).storageText
    }
}

/// Settings ▸ Watching ▸ Subtitles: where Japanese subtitles come from.
struct SubtitlesSettingsView: View {
    @Environment(PlayerEnvironment.self) private var environment

    var body: some View {
        Form {
            Section {
                NavigationLink {
                    JimakuSettingsView()
                } label: {
                    JimakuRow()
                }
                .accessibilityIdentifier("subtitles.jimaku")
                NavigationLink(value: ServerKind.kaku) {
                    ServerRow(kind: .kaku, account: environment.common.serverAccounts[.kaku])
                }
                .accessibilityIdentifier("subtitles.kaku")
            } footer: {
                Text("Jimaku has subtitles for most anime. When it has none, Kaku can make them from the episode's Japanese audio. Episodes with several audio tracks always start on the Japanese one.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Subtitles")
    }
}

/// Settings ▸ Watching ▸ Playback.
struct PlaybackSettingsView: View {
    var body: some View {
        Form {
            Section {
                SkipIntrosToggle()
            } footer: {
                Text("Skips intros and recaps without the button, where Jellyfin knows them.")
            }
            JapaneseAudioOnlySection()
        }
        .formStyle(.grouped)
        .navigationTitle("Playback")
    }
}

/// Settings ▸ Storage: what Miru keeps on this device.
struct StorageView: View {
    @Environment(PlayerEnvironment.self) private var environment
    @State private var dictionaryBytes: Int64 = 0
    @State private var subtitleBytes: Int64 = 0

    private var downloadBytes: Int64 {
        environment.downloader.records.values.reduce(0) { $0 + ($1.state == .done ? ($1.bytesTotal ?? 0) : $1.bytesDone) }
    }

    var body: some View {
        Form {
            Section {
                StorageSummary(parts: [
                    .init("Downloads", bytes: downloadBytes, color: .blue),
                    .init("Dictionaries", bytes: dictionaryBytes, color: .purple),
                    .init("Subtitles", bytes: subtitleBytes, color: .indigo),
                ])
            }
            Section {
                NavigationLink {
                    DownloadedEpisodesView()
                } label: {
                    SettingsRowLabel("Downloads", value: downloadBytes.storageText, systemImage: "arrow.down.circle.fill", color: .blue)
                }
                .accessibilityIdentifier("storage.downloads")
                NavigationLink {
                    DictionariesView()
                } label: {
                    SettingsRowLabel("Dictionaries", value: dictionaryBytes.storageText, systemImage: "character.book.closed.ja", color: .purple)
                }
            }
            SavedSubtitlesSection()
        }
        .formStyle(.grouped)
        .navigationTitle("Storage")
        .onAppear {
            dictionaryBytes = environment.common.dictionaries.totalBytes()
            subtitleBytes = Int64((try? environment.transcripts.approximateBytes()) ?? 0)
        }
    }
}

/// Saved subtitles (the Lines tab) and how much room they take; part of Settings ▸ Storage.
struct SavedSubtitlesSection: View {
    @Environment(PlayerEnvironment.self) private var environment
    @State private var transcriptBytes = 0
    @State private var confirmsClear = false

    var body: some View {
        Section {
            LabeledContent("Saved subtitles", value: transcriptBytes.storageText)
            Button("Clear Saved Subtitles", role: .destructive) { confirmsClear = true }
                .disabled(transcriptBytes == 0)
                .confirmationDialog("Clear saved subtitles?", isPresented: $confirmsClear, titleVisibility: .visible) {
                    Button("Clear", role: .destructive) {
                        try? environment.transcripts.clear()
                        measure()
                    }
                } message: {
                    Text("Lines will fetch an episode's subtitles again the next time you open it.")
                }
        } header: {
            Text("Saved Subtitles")
        } footer: {
            Text("Japanese subtitles of episodes you've watched or opened in Lines, for reading and search.")
        }
        .onAppear(perform: measure)
    }

    private func measure() {
        transcriptBytes = (try? environment.transcripts.approximateBytes()) ?? 0
    }
}

/// Skips intros and recaps without the button (Jellyfin's segments, e.g. from Intro Skipper).
struct SkipIntrosToggle: View {
    @Environment(CommonEnvironment.self) private var common
    @State private var settings = PlayerSettings()

    var body: some View {
        Toggle("Skip Intros Automatically", isOn: Binding(get: { settings.autoSkipsIntros }, set: { value in
            settings.autoSkipsIntros = value
            try? settings.save(common.database)
        }))
        .accessibilityIdentifier("settings.autoSkipIntros")
        .onAppear { settings = PlayerSettings.load(common.database) }
    }
}

/// A mined card's picture: a still frame, or the line as an animated GIF.
struct CardPicturePicker: View {
    @Environment(CommonEnvironment.self) private var common
    @State private var settings = PlayerSettings()

    var body: some View {
        Picker("Card Picture", selection: Binding(get: { settings.cardPicture }, set: { value in
            settings.cardPicture = value
            try? settings.save(common.database)
        })) {
            Text("Screenshot").tag(PlayerSettings.CardPicture.screenshot)
            Text("Animated").tag(PlayerSettings.CardPicture.animated)
        }
        .accessibilityIdentifier("settings.cardPicture")
        .onAppear { settings = PlayerSettings.load(common.database) }
    }
}
