import AppCommon
import Core
import JellyfinKit
import SwiftUI

/// Miru's parts of first-launch setup.
enum MiruSetup {
    static let info = SetupAppInfo(
        name: "Miru", tagline: "Watch anime and films from Jellyfin with Japanese subtitles you can tap to look up and mine.",
        serverName: "Jellyfin", serverDetail: "Your anime and films", startTitle: "Start Watching")

    @MainActor static func checklist(_ environment: PlayerEnvironment) -> [SetupChecklistItem] {
        let common = environment.common
        let jimaku = ((try? common.secrets.secret(for: .jimakuAPIKey)) ?? nil) != nil
        let kechimochi = ((try? common.activity.kechimochiURL()) ?? nil) != nil
        return [
            SetupChecklistItem.server("Jellyfin", account: common.serverAccounts[.jellyfin], settings: "Settings → Watching"),
            SetupChecklistItem("Jimaku subtitles", detail: jimaku ? "Key set" : "In Settings → Watching → Subtitles", isDone: jimaku),
            SetupChecklistItem("Kaku subtitles", detail: common.serverAccounts[.kaku] != nil ? "Connected" : "In Settings → Watching → Subtitles",
                               isDone: common.serverAccounts[.kaku] != nil),
            SetupChecklistItem("kechimochi", detail: kechimochi ? "Linked from Stats" : "Optional · In Settings → Stats", isDone: kechimochi),
        ]
    }
}

/// Step 2: Jellyfin's address, username and password, signed in inline.
struct MiruServerStep: View {
    @Environment(PlayerEnvironment.self) private var environment
    @Environment(SetupFlow.self) private var flow
    @State private var model: JellyfinSettingsModel?
    @State private var found: String?

    var body: some View {
        if let model {
            @Bindable var model = model
            let connected = model.isSignedIn && model.status != .working && !isFailed(model.status)
            SetupPage(step: .server, systemImage: "server.rack", title: "Connect Jellyfin",
                      subtitle: "Miru streams your anime and films from your Jellyfin server.",
                      buttonTitle: connected ? "Continue" : "Sign In", canContinue: connected || model.canSignIn,
                      action: {
                          if connected { flow.advance(from: .server) } else { Task { await connect(model) } }
                      }) {
                SetupCard {
                    TextField("Server URL", text: $model.urlText, prompt: Text(verbatim: "https://jellyfin.example.ts.net"))
                        .urlEntry()
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .accessibilityIdentifier("setup.server.url")
                    Divider().padding(.leading, 16)
                    TextField("Username", text: $model.username)
                        .credentialEntry()
                        .textContentType(.username)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .accessibilityIdentifier("setup.server.username")
                    Divider().padding(.leading, 16)
                    SecureField("Password", text: $model.password)
                        .textContentType(.password)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .accessibilityIdentifier("setup.server.password")
                }
                Text("Only a sign-in token is kept, never the password.")
                    .font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                Group {
                    if let found, case .ok = model.status {
                        Label(found, systemImage: "checkmark").foregroundStyle(.green)
                    } else if model.isSignedIn, model.status == .idle {
                        Label("Connected · \(environment.common.serverAccounts[.jellyfin]?.hostAndAccount ?? "Jellyfin")", systemImage: "checkmark")
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
                model = JellyfinSettingsModel(environment: environment.common)
            }
        }
    }

    private func isFailed(_ status: ConnectionStatus) -> Bool {
        if case .failed = status { true } else { false }
    }

    private func connect(_ model: JellyfinSettingsModel) async {
        await model.signIn()
        guard case .ok = model.status, let client = environment.jellyfinClient() else { return }
        let count = ((try? await client.views()) ?? []).count
        found = "Connected · Jellyfin · \(count == 1 ? "1 library" : "\(count) libraries") found"
    }
}

/// Step 3: which Jellyfin libraries show. The guess: a Japanese name, or Japanese audio in
/// the library's newest items.
struct MiruLibrariesStep: View {
    @Environment(PlayerEnvironment.self) private var environment
    @Environment(SetupFlow.self) private var flow
    @State private var libraries: [JellyfinItem]?
    @State private var problem: String?

    var body: some View {
        SetupLibrariesStep(
            libraries: libraries?.map { SetupLibrary(id: $0.id, name: $0.name, detail: $0.collectionType == "movies" ? "Films" : "Shows") },
            problem: problem,
            isShown: { !environment.hiddenLibraries.contains($0) },
            setShown: { id, shown in try? environment.libraryVisibility.setHidden(id, hidden: !shown) })
            .task { await load() }
    }

    private func load() async {
        guard let client = environment.jellyfinClient() else { problem = "Jellyfin isn't connected."; return }
        do {
            let all = try await client.views()
            var japanese: [String: Bool] = [:]
            for library in all {
                japanese[library.id] = LibraryGuess.isJapanese(library.name) ? true : await Self.hasJapaneseAudio(library, client: client)
            }
            flow.guessLibrariesOnce {
                for library in all { try? environment.libraryVisibility.setHidden(library.id, hidden: japanese[library.id] != true) }
            }
            libraries = all
        } catch {
            problem = error.localizedDescription
        }
    }

    /// Any of the three newest items with a Japanese track (a series by its first episode).
    private static func hasJapaneseAudio(_ library: JellyfinItem, client: JellyfinClient) async -> Bool {
        guard let items = try? await client.recentlyAdded(libraryId: library.id, limit: 3, withStreams: true) else { return false }
        for item in items {
            if item.type == "Series" {
                if let episode = try? await client.firstEpisode(seriesId: item.id), episode.hasJapaneseAudio { return true }
            } else if item.hasJapaneseAudio {
                return true
            }
        }
        return false
    }
}

/// Step 8: Miru's extras.
struct MiruSetupExtras: View {
    @Environment(PlayerEnvironment.self) private var environment

    var body: some View {
        let common = environment.common
        SetupExtraRow("Jimaku", detail: "Japanese subtitles for most anime", recommended: true,
                      isDone: ((try? common.secrets.secret(for: .jimakuAPIKey)) ?? nil) != nil) {
            JimakuSettingsView()
        }
        Divider().padding(.leading, 16)
        SetupExtraRow("Kaku", detail: "Makes subtitles from the Japanese audio when Jimaku has none", recommended: true,
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
