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
        #elseif DEBUG
        UIDevice.current.userInterfaceIdiom == .pad || ProcessInfo.processInfo.environment["UITEST_PLAYER"] != nil
        #else
        UIDevice.current.userInterfaceIdiom == .pad
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
                        SettingsRowLabel("Playback", subtitle: "Skip intros, quality, cellular", systemImage: "play.rectangle.fill", color: .red)
                    }
                    .accessibilityIdentifier("settings.playback")
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

                #if os(iOS)
                // Spike (never merged): the AetherEngine device test.
                Section {
                    Toggle("Play with AetherEngine", isOn: $aetherTest)
                        .accessibilityIdentifier("settings.aetherTest")
                } header: {
                    Text("Test")
                } footer: {
                    Text("Episodes open in a plain test player that uses AetherEngine instead of mpv. It doesn't save your place or mark episodes watched. Turn it off to go back to the normal player.")
                }
                #endif

                LookupSection()

                AnkiSection {
                    Self.anki(environment)
                }

                ConnectionsSection {
                    NavigationLink(value: ServerKind.jellyfin) {
                        SettingsRowLabel("Jellyfin", subtitle: accounts[.jellyfin]?.hostAndAccount ?? "Not set up",
                                         systemImage: "server.rack", color: .indigo, dot: accounts[.jellyfin]?.dotColor)
                    }
                    .accessibilityIdentifier("settings.jellyfin")
                    NavigationLink {
                        JimakuSettingsView()
                    } label: {
                        JimakuRow()
                    }
                    .accessibilityIdentifier("settings.jimaku")
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
                    AboutView(appCredits: Self.credits)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Settings")
            .navigationDestination(for: ServerKind.self) { Self.serverPage($0, environment: environment) }
            .task { measureStorage() }
            .task(id: accounts[.jellyfin]?.baseURL) {
                libraryIDs = try? await environment.jellyfinClient()?.views().map(\.id)
            }
        }
    }

    @AppStorage(AetherTest.key) private var aetherTest = false
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

    static var advanced: some View {
        AdvancedSettingsView(kinds: [.ankiNote, .jellyfinProgress, .jellyfinPlayed, .jellyfinSubtitle],
                             extraLogs: ["dev-setup.log", "nowplaying.log"].map { URL.applicationSupportDirectory.appending(path: $0) })
    }


    static func anki(_ environment: PlayerEnvironment) -> some View {
        AnkiSettingsPage(environment: environment.common) { CardPicturePicker() }
    }

    /// What a link to a server opens.
    @ViewBuilder static func serverPage(_ kind: ServerKind, environment: PlayerEnvironment) -> some View {
        switch kind {
        case .jellyfin: JellyfinSettingsView(environment: environment.common)
        case .anki: anki(environment)
        case .kaku: KakuSettingsView(environment: environment.common)
        case .kavita, .audiobookshelf: EmptyView()
        }
    }

    private var statusItems: [StatusItem] { Self.statusItems(environment) }

    static func statusItems(_ environment: PlayerEnvironment) -> [StatusItem] {
        let accounts = environment.common.serverAccounts
        return [
            StatusItem("Jellyfin", isSetUp: accounts[.jellyfin] != nil, opens: { AnyView(serverPage(.jellyfin, environment: environment)) }) {
                _ = try await environment.jellyfinClient()?.currentUser()
            },
            StatusItem("Anki", isSetUp: accounts[.anki] != nil, opens: { AnyView(serverPage(.anki, environment: environment)) }) {
                _ = try await environment.common.ankiClient()?.version()
            },
            StatusItem("Jimaku", isSetUp: ((try? environment.common.secrets.secret(for: .jimakuAPIKey)) ?? nil) != nil, opens: { AnyView(JimakuSettingsView()) }) {
                _ = try await environment.jimakuClient()?.search(query: "テスト")
            },
            StatusItem("Kaku", isSetUp: accounts[.kaku] != nil, opens: { AnyView(serverPage(.kaku, environment: environment)) }) {
                _ = try await environment.kakuClient()?.health()
            },
            StatusItem("kechimochi", isSetUp: ((try? environment.common.activity.kechimochiURL()) ?? nil) != nil, opens: { AnyView(KechimochiPage()) }) {
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

#if os(macOS)
/// The Mac's Settings window: the same pages as the list above, each in the sidebar.
struct MacSettingsView: View {
    @Environment(PlayerEnvironment.self) private var environment

    var body: some View {
        MacSettingsWindow(groups: [
            MacSettingsGroup(pages: [.overview(PlayerSettingsView.statusItems(environment))]),
            MacSettingsGroup("Watching", pages: [
                MacSettingsPage("libraries", title: "Libraries", systemImage: "books.vertical",
                                keywords: ["Japanese Audio Only"]) { JellyfinLibrariesSettingsView() },
                MacSettingsPage("subtitles", title: "Subtitles", systemImage: "captions.bubble",
                                keywords: ["Hide Until Tapped", "Pause Under the Pointer", "Position", "Size"]) { SubtitlesSettingsView() },
                MacSettingsPage("playback", title: "Playback", systemImage: "play.rectangle",
                                keywords: ["Skip Intros Automatically", "Streaming Quality"]) { PlaybackSettingsView() },
                MacSettingsPage("shortcuts", title: "Keyboard Shortcuts", systemImage: "keyboard", keywords: ["Keys"]) { PlayerShortcutsView() },
            ]),
        ] + MacSettingsGroup.shared(servers: [
            MacSettingsPage("jellyfin", title: "Jellyfin", systemImage: "server.rack") { JellyfinSettingsView(environment: environment.common) },
            MacSettingsPage("jimaku", title: "Jimaku", systemImage: "captions.bubble") { JimakuSettingsView() },
            MacSettingsPage("kaku", title: "Kaku", systemImage: "text.quote") { KakuSettingsView(environment: environment.common) },
        ]) {
            PlayerSettingsView.anki(environment)
        } + [
            .footer(storageKeywords: ["Saved Subtitles"]) {
                StorageView()
            } advanced: {
                PlayerSettingsView.advanced
            } about: {
                AboutView(appCredits: PlayerSettingsView.credits)
            },
        ]) { kind in
            PlayerSettingsView.serverPage(kind, environment: environment)
        }
    }
}
#endif

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
                // A destination push, like the screen it's on (Subtitles is pushed that way): a value
                // push from a destination-pushed screen is the mix behind #145.
                NavigationLink {
                    KakuSettingsView(environment: environment.common)
                } label: {
                    ServerRow(kind: .kaku, account: environment.common.serverAccounts[.kaku])
                }
                .accessibilityIdentifier("subtitles.kaku")
            } footer: {
                Text("Jimaku has subtitles for most anime. When it has none, Kaku can make them from the episode's Japanese audio. Episodes with several audio tracks always start on the Japanese one.")
            }
            SubtitleLookSection()
        }
        .formStyle(.grouped)
        .navigationTitle("Subtitles")
    }
}

/// How the Japanese line looks and behaves in the player (also in the player's options menu).
struct SubtitleLookSection: View {
    @Environment(CommonEnvironment.self) private var common
    @State private var settings = PlayerSettings()

    var body: some View {
        Section {
            Picker("Size", selection: binding(\.subtitleScale)) {
                ForEach(PlayerSettings.subtitleScales, id: \.scale) { Text($0.name).tag($0.scale) }
            }
            Picker("Position", selection: binding(\.subtitleLift)) {
                ForEach(PlayerSettings.subtitleLifts, id: \.lift) { Text($0.name).tag($0.lift) }
            }
            Toggle("Hide Until Tapped", isOn: binding(\.concealsSubtitles))
                .accessibilityIdentifier("subtitles.conceal")
            #if os(macOS)
            Toggle("Pause Under the Pointer", isOn: binding(\.pausesOnHover))
            #endif
        } header: {
            Text("In the Player")
        } footer: {
            #if os(macOS)
            Text("Higher positions clear subtitles burnt into the picture. Hide Until Tapped blurs each Japanese line until you click or point at it, to listen first. Pause Under the Pointer stops the video while the pointer rests on the line.")
            #else
            Text("Higher positions clear subtitles burnt into the picture. Hide Until Tapped blurs each Japanese line until you tap it, to listen first.")
            #endif
        }
        .onAppear { settings = PlayerSettings.load(common.database) }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<PlayerSettings, Value>) -> Binding<Value> {
        Binding(get: { settings[keyPath: keyPath] }, set: { value in
            settings[keyPath: keyPath] = value
            try? settings.save(common.database)
        })
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
            StreamQualitySection()
            // Was its own Downloads page; the same stored setting.
            DownloadSettingsSection { _ in }
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
                    .init("Downloaded", bytes: downloadBytes, color: .blue),
                    .init("Dictionaries", bytes: dictionaryBytes, color: .purple),
                    .init("Subtitles", bytes: subtitleBytes, color: .indigo),
                ])
            }
            Section {
                NavigationLink {
                    DownloadedEpisodesView()
                } label: {
                    SettingsRowLabel("Downloaded", value: downloadBytes.storageText, systemImage: "arrow.down.circle.fill", color: .blue)
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
            HStack {
                SettingsRowLabel("Saved Subtitles", value: transcriptBytes.storageText, systemImage: "captions.bubble.fill", color: .indigo)
                Button("Clear", role: .destructive) { confirmsClear = true }
                    #if os(iOS)
                    .buttonStyle(.borderless)
                    #endif
                    .disabled(transcriptBytes == 0)
                    .accessibilityIdentifier("storage.clearSubtitles")
            }
            .confirmationDialog("Clear saved subtitles?", isPresented: $confirmsClear, titleVisibility: .visible) {
                Button("Clear Subtitles", role: .destructive) {
                    try? environment.transcripts.clear()
                    measure()
                }
            } message: {
                Text("Lines will fetch an episode's subtitles again the next time you open it.")
            }
        } footer: {
            Text("Subtitles of episodes you've watched or opened in Lines, for reading and search.")
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

/// Settings ▸ Playback ▸ Streaming Quality: the original file, or a smaller stream that Jellyfin
/// makes for slow connections.
struct StreamQualitySection: View {
    @Environment(PlayerEnvironment.self) private var environment
    @State private var bitrate = 0

    var body: some View {
        Section {
            Picker("Streaming Quality", selection: $bitrate) {
                ForEach(PlayerSettings.streamQualities, id: \.bitrate) { quality in
                    Text(quality.name).tag(quality.bitrate)
                }
            }
            .accessibilityIdentifier("settings.streamQuality")
        } footer: {
            Text("Original plays the file as it is. A lower quality has Jellyfin make a smaller stream of files above it, for slow connections; the player's menu changes it while watching. Downloads and cards always use the original.")
        }
        .onAppear { bitrate = PlayerSettings.load(environment.common.database).maxStreamBitrate }
        .onChange(of: bitrate) {
            var settings = PlayerSettings.load(environment.common.database)
            guard settings.maxStreamBitrate != bitrate else { return }
            settings.maxStreamBitrate = bitrate
            try? settings.save(environment.common.database)
        }
    }
}
