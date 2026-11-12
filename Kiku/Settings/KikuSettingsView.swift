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
                    NavigationLink(value: ServerKind.audiobookshelf) {
                        SettingsRowLabel("Audiobookshelf", subtitle: accounts[.audiobookshelf]?.hostAndAccount ?? "Not set up",
                                         systemImage: "server.rack", color: .indigo, dot: accounts[.audiobookshelf]?.dotColor)
                    }
                    .accessibilityIdentifier("settings.audiobookshelf")
                    NavigationLink {
                        KikuLibrariesSettingsView()
                    } label: {
                        SettingsRowLabel("Libraries", systemImage: "books.vertical.fill", color: .orange)
                    }
                    .accessibilityIdentifier("settings.libraries")
                    NavigationLink(value: ServerKind.kaku) {
                        SettingsRowLabel("Transcripts", subtitle: accounts[.kaku].map { "Kaku · \($0.hostAndAccount)" } ?? "Kaku · not set up",
                                         systemImage: "text.quote", color: .teal, dot: accounts[.kaku]?.dotColor)
                    }
                    .accessibilityIdentifier("settings.transcripts")
                    NavigationLink {
                        Form {
                            Section {
                                SkipIntervalPickers()
                            } footer: {
                                Text("For the Lock Screen, AirPods and CarPlay. The player's own buttons jump by lines.")
                            }
                        }
                        .formStyle(.grouped)
                        .navigationTitle("Playback")
                    } label: {
                        SettingsRowLabel("Playback", subtitle: "Lock Screen skip intervals", systemImage: "play.circle.fill", color: .red)
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
                } header: {
                    Text("Listening")
                } footer: {
                    Text("Transcripts come from Kaku. Without it, episodes play without their text.")
                }

                LookupAndMiningSection {
                    AnkiSettingsPage(environment: environment.common)
                }

                StatsSettingsLink()

                SettingsFooterSection(storageTotal: storageTotal) {
                    StorageView()
                } advanced: {
                    AdvancedSettingsView(kinds: [.ankiNote, .audiobookshelfProgress],
                                         extraLogs: [URL.applicationSupportDirectory.appending(path: "dev-setup.log")])
                } about: {
                    AboutView(appCredits: [])
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Settings")
            .navigationDestination(for: ServerKind.self) { kind in
                switch kind {
                case .audiobookshelf: AudiobookshelfSettingsView(environment: environment.common, tokens: environment.tokens, appName: "Kiku")
                case .kaku: KakuSettingsView(environment: environment.common)
                case .anki: AnkiSettingsPage(environment: environment.common)
                case .kavita, .jellyfin: EmptyView()
                }
            }
            .onAppear {
                let downloads = environment.downloader.records.values.reduce(Int64(0)) { $0 + ($1.state == .done ? ($1.bytesTotal ?? 0) : $1.bytesDone) }
                let transcripts = Int64((try? environment.transcripts.approximateBytes()) ?? 0)
                storageTotal = (downloads + transcripts + environment.common.dictionaries.totalBytes()).storageText
            }
        }
    }

    private var statusItems: [StatusItem] {
        [
            StatusItem("Audiobookshelf", isSetUp: accounts[.audiobookshelf] != nil) {
                _ = try await environment.audiobookshelfClient()?.me()
            },
            StatusItem("Kaku", isSetUp: accounts[.kaku] != nil) {
                _ = try await environment.kakuClient()?.health()
            },
            StatusItem("Anki", isSetUp: accounts[.anki] != nil) {
                _ = try await environment.common.ankiClient()?.version()
            },
            StatusItem("kechimochi", isSetUp: ((try? environment.common.activity.kechimochiURL()) ?? nil) != nil) {
                try await environment.common.checkKechimochi()
            },
        ]
    }
}

/// Settings ▸ Storage: what Kiku keeps on this device.
struct StorageView: View {
    @Environment(KikuEnvironment.self) private var environment
    @State private var dictionaryBytes: Int64 = 0
    @State private var transcriptBytes: Int64 = 0

    private var downloadBytes: Int64 {
        environment.downloader.records.values.reduce(0) { $0 + ($1.state == .done ? ($1.bytesTotal ?? 0) : $1.bytesDone) }
    }

    var body: some View {
        Form {
            Section {
                StorageSummary(parts: [
                    .init("Downloads", bytes: downloadBytes, color: .blue),
                    .init("Dictionaries", bytes: dictionaryBytes, color: .purple),
                    .init("Transcripts", bytes: transcriptBytes, color: .teal),
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
                SettingsRowLabel("Saved Transcripts", value: transcriptBytes.storageText, systemImage: "text.quote", color: .teal)
            } footer: {
                Text("Transcripts of episodes you've played or downloaded, for the player offline and Marks search.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Storage")
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
                        Text("Sign in to Audiobookshelf to choose libraries.").foregroundStyle(.secondary)
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
