import AppCommon
import Core
import SwiftUI

/// Kiku's parts of first-launch setup.
enum KikuSetup {
    static let info = SetupAppInfo(
        name: "Kiku", tagline: "Listen to Japanese podcasts and audiobooks from Audiobookshelf, with transcripts from Kaku that you can tap to look up.",
        serverName: "Audiobookshelf", serverDetail: "Your podcasts and audiobooks", startTitle: "Start Listening")

    @MainActor static func checklist(_ environment: KikuEnvironment) -> [SetupChecklistItem] {
        let common = environment.common
        let shelf = common.serverAccounts[.audiobookshelf]
        let kechimochi = ((try? common.activity.kechimochiURL()) ?? nil) != nil
        return [
            SetupChecklistItem.server("Audiobookshelf", account: shelf, settings: "Settings → Listening"),
            SetupChecklistItem("Kaku transcripts", detail: common.serverAccounts[.kaku] != nil ? "Connected" : "In Settings → Listening → Transcripts",
                               isDone: common.serverAccounts[.kaku] != nil),
            SetupChecklistItem("kechimochi", detail: kechimochi ? "Linked from Stats" : "Optional · In Settings → Stats", isDone: kechimochi),
        ]
    }
}

/// Step 2: Audiobookshelf's address, with a password or an API key, signed in inline.
struct KikuServerStep: View {
    @Environment(KikuEnvironment.self) private var environment
    @Environment(SetupFlow.self) private var flow
    @State private var model: AudiobookshelfSettingsModel?
    @State private var found: String?

    var body: some View {
        if let model {
            @Bindable var model = model
            let connected = model.isSignedIn && model.status != .working && !isFailed(model.status)
            SetupPage(step: .server, systemImage: "server.rack", title: "Connect Audiobookshelf",
                      subtitle: "Kiku plays your podcasts and audiobooks from your Audiobookshelf server.",
                      buttonTitle: connected ? "Continue" : "Sign In", canContinue: connected || model.canSignIn,
                      action: {
                          if connected { flow.advance(from: .server) } else { Task { await connect(model) } }
                      }) {
                Picker("Sign in with", selection: $model.method) {
                    Text("Password").tag(AudiobookshelfSettingsModel.Method.password)
                    Text("API Key").tag(AudiobookshelfSettingsModel.Method.apiKey)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("setup.server.method")
                SetupCard {
                    TextField("Server URL", text: $model.urlText, prompt: Text(verbatim: "https://audiobookshelf.example.ts.net"))
                        .urlEntry()
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .accessibilityIdentifier("setup.server.url")
                    Divider().padding(.leading, 16)
                    if model.method == .password {
                        TextField("Username", text: $model.username)
                            .credentialEntry()
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .accessibilityIdentifier("setup.server.username")
                        Divider().padding(.leading, 16)
                        SecureField("Password", text: $model.password)
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .accessibilityIdentifier("setup.server.password")
                    } else {
                        SecureField("API Key", text: $model.apiKey)
                            .credentialEntry()
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .accessibilityIdentifier("setup.server.key")
                    }
                }
                Group {
                    if let found, case .ok = model.status {
                        Label(found, systemImage: "checkmark").foregroundStyle(.green)
                    } else if model.isSignedIn, model.status == .idle {
                        Label("Connected · \(environment.common.serverAccounts[.audiobookshelf]?.hostAndAccount ?? "Audiobookshelf")", systemImage: "checkmark")
                            .foregroundStyle(.green)
                    } else {
                        ConnectionStatusView(status: model.status)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("setup.server.status")
            }
        } else {
            Color.clear.onAppear {
                model = AudiobookshelfSettingsModel(environment: environment.common, tokens: environment.tokens)
            }
        }
    }

    private func isFailed(_ status: ConnectionStatus) -> Bool {
        if case .failed = status { true } else { false }
    }

    private func connect(_ model: AudiobookshelfSettingsModel) async {
        await model.signIn()
        guard case .ok = model.status else { return }
        await environment.library.refreshLibraries()
        let count = environment.library.libraries.count
        found = "Connected · Audiobookshelf · \(count == 1 ? "1 library" : "\(count) libraries") found"
    }
}

/// Step 3: which Audiobookshelf libraries show.
struct KikuLibrariesStep: View {
    @Environment(KikuEnvironment.self) private var environment
    @Environment(SetupFlow.self) private var flow
    @State private var loaded = false

    var body: some View {
        let library = environment.library
        SetupLibrariesStep(
            libraries: loaded ? library.libraries.map {
                SetupLibrary(id: $0.id, name: $0.name, detail: $0.mediaType == .book ? "Audiobooks" : "Podcasts")
            } : nil,
            problem: loaded || environment.audiobookshelfClient() != nil ? nil : "Audiobookshelf isn't connected.",
            isShown: { !library.hiddenLibraries.contains($0) },
            setShown: { id, shown in Task { await library.setHidden(id, !shown) } })
            .task {
                await library.refreshLibraries()
                let all = library.libraries
                var guess: [String: Bool] = [:]
                flow.guessLibrariesOnce {
                    for item in all { guess[item.id] = LibraryGuess.isJapanese(item.name) }
                }
                for (id, japanese) in guess { await library.setHidden(id, !japanese) }
                loaded = true
            }
    }
}

/// Step 8: Kiku's extras.
struct KikuSetupExtras: View {
    @Environment(KikuEnvironment.self) private var environment

    var body: some View {
        let common = environment.common
        SetupExtraRow("Kaku", detail: "Needed for transcripts: without it episodes play without their text", recommended: true,
                      isDone: common.serverAccounts[.kaku] != nil) {
            KakuSettingsView(environment: common)
        }
        Divider().padding(.leading, 16)
        SetupExtraRow("kechimochi", detail: "Your immersion log, linked from Stats",
                      isDone: ((try? common.activity.kechimochiURL()) ?? nil) != nil) {
            Form { StatsSettingsSection() }.formStyle(.grouped).navigationTitle("kechimochi")
        }
    }
}
