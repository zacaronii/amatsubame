import AppCommon
import Core
import SwiftUI

struct KikuSettingsView: View {
    @Environment(KikuEnvironment.self) private var environment
    @State private var storageTotal: String?

    private var accounts: [ServerKind: ServerAccount] { environment.common.serverAccounts }

    var body: some View {
        NavigationStack {
            Form {
                SettingsStatusCard(items: statusItems)

                Section {
                    NavigationLink {
                        KikuLibrariesSettingsView()
                    } label: {
                        SettingsRowLabel("Libraries", value: librariesSummary, systemImage: "books.vertical.fill", color: .orange)
                    }
                    .accessibilityIdentifier("settings.libraries")
                    NavigationLink {
                        Self.playback
                    } label: {
                        SettingsRowLabel("Playback", subtitle: "Skip intervals, playing the next episode", systemImage: "play.circle.fill", color: .red)
                    }
                    .accessibilityIdentifier("settings.playback")
                    NavigationLink {
                        KikuDownloadSettingsView()
                    } label: {
                        SettingsRowLabel("Download Rules", subtitle: "Over cellular, download ahead", systemImage: "arrow.down.circle.fill", color: .blue)
                    }
                    .accessibilityIdentifier("settings.downloads")
                    #if os(iOS)
                    NavigationLink {
                        AppleWatchSettingsView()
                    } label: {
                        SettingsRowLabel("Apple Watch", subtitle: environment.watchLibrary.isWatchAppInstalled ? "Live Text, downloads" : "Kiku isn\u{2019}t on your watch",
                                         systemImage: "applewatch", color: .gray)
                    }
                    .accessibilityIdentifier("settings.appleWatch")
                    #endif
                } header: {
                    Text("Listening")
                }

                LookupSection()

                AnkiSection {
                    AnkiSettingsPage(environment: environment.common)
                }

                ConnectionsSection {
                    NavigationLink(value: ServerKind.audiobookshelf) {
                        SettingsRowLabel("Audiobookshelf", subtitle: accounts[.audiobookshelf]?.hostAndAccount ?? "Not set up",
                                         systemImage: "server.rack", color: .indigo, dot: accounts[.audiobookshelf]?.dotColor)
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
                    AboutView(appCredits: [])
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Settings")
            // For the Libraries row's "N of M".
            .task { if environment.library.libraries.isEmpty { await environment.library.refreshLibraries() } }
            .navigationDestination(for: ServerKind.self) { Self.serverPage($0, environment: environment) }
            .onAppear {
                let downloads = environment.downloader.records.values.reduce(Int64(0)) { $0 + ($1.state == .done ? ($1.bytesTotal ?? 0) : $1.bytesDone) }
                let transcripts = Int64((try? environment.transcripts.approximateBytes()) ?? 0)
                storageTotal = (downloads + transcripts + environment.common.dictionaries.totalBytes()).storageText
            }
        }
    }

    private var librariesSummary: String? {
        let libraries = environment.library.libraries
        guard !libraries.isEmpty else { return nil }
        let hidden = environment.library.hiddenLibraries
        return "\(libraries.filter { !hidden.contains($0.id) }.count) of \(libraries.count)"
    }

    static var playback: some View {
        Form {
            Section {
                SkipIntervalPickers()
            } header: {
                #if os(macOS)
                Text("Skip Intervals")
                #endif
            } footer: {
                #if os(macOS)
                Text("For media keys, Control Center and AirPods. The player's own buttons jump by lines.")
                #else
                Text("For the Lock Screen, AirPods and CarPlay. The player's own buttons jump by lines.")
                #endif
            }
            PlaysNextSection()
        }
        .formStyle(.grouped)
        .navigationTitle("Playback")
    }

    /// When an episode ends, the show's next one starts (on by default).
    private struct PlaysNextSection: View {
        @Environment(KikuEnvironment.self) private var environment
        @State private var isOn = true

        var body: some View {
            Section {
                Toggle("Play the Next Episode", isOn: $isOn)
                    .accessibilityIdentifier("settings.playsNext")
            } footer: {
                Text("When a podcast episode ends, the show's next one starts by itself: the next by date that you haven't finished. The sleep timer's End of Episode still stops there.")
            }
            .onAppear { isOn = ListenSettings.load(environment.common.database).playsNextEpisode }
            .onChange(of: isOn) { _, on in
                var settings = ListenSettings.load(environment.common.database)
                guard settings.playsNextEpisode != on else { return }
                settings.playsNextEpisode = on
                try? settings.save(environment.common.database)
            }
        }
    }

    #if os(iOS)
    /// Live Text on Apple Watch (docs/watch.md): off by default; off, no transcripts go to the watch.
    struct WatchLiveTextSection: View {
        @Environment(KikuEnvironment.self) private var environment
        @State private var isOn = false

        var body: some View {
            Section {
                Toggle("Live Text on Apple Watch", isOn: $isOn)
                    .accessibilityIdentifier("settings.watchLiveText")
            } footer: {
                Text("Kiku on your Apple Watch shows the transcript as it plays. Tap a word there to look it up, and add the card from your wrist.")
            }
            .onAppear { isOn = environment.watch.liveText }
            .onChange(of: isOn) { _, on in
                if on != environment.watch.liveText { environment.watch.setLiveText(on) }
            }
        }
    }
    #endif

    static var advanced: some View {
        AdvancedSettingsView(kinds: [.ankiNote, .audiobookshelfProgress, .audiobookshelfSession],
                             extraLogs: [URL.applicationSupportDirectory.appending(path: "dev-setup.log")])
    }

    /// What a link to a server opens.
    @ViewBuilder static func serverPage(_ kind: ServerKind, environment: KikuEnvironment) -> some View {
        switch kind {
        case .audiobookshelf: AudiobookshelfSettingsView(environment: environment.common, tokens: environment.tokens, appName: "Kiku")
        case .kaku: KakuSettingsView(environment: environment.common)
        case .anki: AnkiSettingsPage(environment: environment.common)
        case .kavita, .jellyfin: EmptyView()
        }
    }

    private var statusItems: [StatusItem] { Self.statusItems(environment) }

    static func statusItems(_ environment: KikuEnvironment) -> [StatusItem] {
        let accounts = environment.common.serverAccounts
        return [
            StatusItem("Audiobookshelf", isSetUp: accounts[.audiobookshelf] != nil, opens: { AnyView(serverPage(.audiobookshelf, environment: environment)) }) {
                _ = try await environment.audiobookshelfClient()?.me()
            },
            StatusItem("Kaku", isSetUp: accounts[.kaku] != nil, opens: { AnyView(serverPage(.kaku, environment: environment)) }) {
                _ = try await environment.kakuClient()?.health()
            },
            StatusItem("Anki", isSetUp: accounts[.anki] != nil, opens: { AnyView(serverPage(.anki, environment: environment)) }) {
                _ = try await environment.common.ankiClient()?.version()
            },
            StatusItem("kechimochi", isSetUp: ((try? environment.common.activity.kechimochiURL()) ?? nil) != nil, opens: { AnyView(KechimochiPage()) }) {
                try await environment.common.checkKechimochi()
            },
        ]
    }
}

#if os(macOS)
/// The Mac's Settings window: the same pages as the list above, each in the sidebar.
struct MacSettingsView: View {
    @Environment(KikuEnvironment.self) private var environment

    var body: some View {
        MacSettingsWindow(groups: [
            MacSettingsGroup(pages: [.overview(KikuSettingsView.statusItems(environment))]),
            MacSettingsGroup("Listening", pages: [
                MacSettingsPage("libraries", title: "Libraries", systemImage: "books.vertical") { KikuLibrariesSettingsView() },
                MacSettingsPage("playback", title: "Playback", systemImage: "play.circle") { KikuSettingsView.playback },
                MacSettingsPage("downloads", title: "Download Rules", systemImage: "arrow.down.circle") { KikuDownloadSettingsView() },
            ]),
        ] + MacSettingsGroup.shared(servers: [
            MacSettingsPage("audiobookshelf", title: "Audiobookshelf", systemImage: "server.rack") {
                KikuSettingsView.serverPage(.audiobookshelf, environment: environment)
            },
            MacSettingsPage("kaku", title: "Kaku", systemImage: "text.quote") { KakuSettingsView(environment: environment.common) },
        ]) {
            AnkiSettingsPage(environment: environment.common)
        } + [
            .footer {
                StorageView()
            } advanced: {
                KikuSettingsView.advanced
            } about: {
                AboutView(appCredits: [])
            },
        ]) { kind in
            KikuSettingsView.serverPage(kind, environment: environment)
        }
    }
}
#endif

/// Settings ▸ Storage: what Kiku keeps on this device.
struct StorageView: View {
    @Environment(KikuEnvironment.self) private var environment
    @State private var dictionaryBytes: Int64 = 0
    @State private var transcriptBytes: Int64 = 0
    @State private var confirmsClearTranscripts = false

    private var downloadBytes: Int64 {
        environment.downloader.records.values.reduce(0) { $0 + ($1.state == .done ? ($1.bytesTotal ?? 0) : $1.bytesDone) }
    }

    var body: some View {
        Form {
            Section {
                StorageSummary(parts: [
                    .init("Downloaded", bytes: downloadBytes, color: .blue),
                    .init("Dictionaries", bytes: dictionaryBytes, color: .purple),
                    .init("Transcripts", bytes: transcriptBytes, color: .teal),
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
                HStack {
                    SettingsRowLabel("Saved Transcripts", value: transcriptBytes.storageText, systemImage: "text.quote", color: .teal)
                    Button("Clear", role: .destructive) { confirmsClearTranscripts = true }
                        #if os(iOS)
                        .buttonStyle(.borderless)
                        #endif
                        .disabled(transcriptBytes == 0)
                        .accessibilityIdentifier("storage.clearTranscripts")
                }
            } footer: {
                Text("Transcripts of episodes you've played or downloaded, for the player offline and Marks search.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Storage")
        .confirmationDialog("Clear saved transcripts?", isPresented: $confirmsClearTranscripts, titleVisibility: .visible) {
            Button("Clear Transcripts", role: .destructive) {
                try? environment.transcripts.clearAll()
                transcriptBytes = Int64((try? environment.transcripts.approximateBytes()) ?? 0)
            }
        } message: {
            Text("They download again when you play an episode with your server in reach. Until then, Marks search can't find lines in them.")
        }
        .onAppear {
            dictionaryBytes = environment.common.dictionaries.totalBytes()
            transcriptBytes = Int64((try? environment.transcripts.approximateBytes()) ?? 0)
        }
    }
}

/// The Lock Screen and AirPods skips (the player's buttons jump by lines instead).
private struct SkipIntervalPickers: View {
    @Environment(KikuEnvironment.self) private var environment
    @State private var settings = ListenSettings()

    var body: some View {
        Group {
            Picker("Skip Back", selection: binding(\.skipBackward)) {
                ForEach(ListenSettings.skipChoices, id: \.self) { Text("\(Int($0)) seconds").tag($0) }
            }
            Picker("Skip Forward", selection: binding(\.skipForward)) {
                ForEach(ListenSettings.skipChoices, id: \.self) { Text("\(Int($0)) seconds").tag($0) }
            }
        }
        .onAppear { settings = ListenSettings.load(environment.common.database) }
    }

    private func binding(_ keyPath: WritableKeyPath<ListenSettings, Double>) -> Binding<Double> {
        Binding(get: { settings[keyPath: keyPath] }, set: { value in
            settings[keyPath: keyPath] = value
            try? settings.save(environment.common.database)
            environment.playback?.audio.skipIntervals = (settings.skipBackward, settings.skipForward)
        })
    }
}

/// Turns Audiobookshelf libraries on and off in Kiku, like Yomu's and Miru's Libraries screens.
struct KikuLibrariesSettingsView: View {
    @Environment(KikuEnvironment.self) private var environment
    @State private var loading = true

    var body: some View {
        Form {
            Section {
                if environment.library.libraries.isEmpty {
                    if loading && environment.audiobookshelfClient() != nil {
                        ProgressView()
                    } else {
                        Text(environment.audiobookshelfClient() == nil ? "Sign in to Audiobookshelf to choose libraries."
                             : "Couldn\u{2019}t reach Audiobookshelf.")
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(environment.library.libraries) { library in
                    Toggle(isOn: Binding(get: { !environment.library.hiddenLibraries.contains(library.id) },
                                         set: { shown in Task { await environment.library.setHidden(library.id, !shown) } })) {
                        Label(library.name, systemImage: library.mediaType == .book ? "book.closed" : "dot.radiowaves.left.and.right")
                    }
                    .accessibilityIdentifier("settings.library")
                }
            } footer: {
                Text("Turned-off libraries are hidden from the Listen tab. Turn off a library you don't listen to in Japanese.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Libraries")
        .task {
            await environment.library.refreshLibraries()
            loading = false
        }
    }
}
