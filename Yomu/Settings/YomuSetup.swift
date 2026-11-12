import AppCommon
import Core
import KavitaKit
import OCR
import SwiftUI

/// Yomu's parts of first-launch setup.
enum YomuSetup {
    static let info = SetupAppInfo(
        name: "Yomu", tagline: "Read manga and books from Kavita. Tap any word to look it up and send it to Anki.",
        serverName: "Kavita", serverDetail: "Your manga and books", startTitle: "Start Reading")

    @MainActor static func checklist(_ environment: AppEnvironment) -> [SetupChecklistItem] {
        return [
            SetupChecklistItem.server("Kavita", account: environment.serverAccounts[.kavita], settings: "Settings → Reading"),
            SetupChecklistItem("Manga text recognition", detail: environment.ocrModels.state == .installed ? "Models installed" : "In Settings → Reading",
                               isDone: environment.ocrModels.state == .installed),
            SetupChecklistItem("Read-Along", detail: environment.serverAccounts[.audiobookshelf] != nil ? "Audiobookshelf connected" : "Optional · In Settings → Reading",
                               isDone: environment.serverAccounts[.audiobookshelf] != nil),
            SetupChecklistItem("kechimochi", detail: ((try? environment.common.activity.kechimochiURL()) ?? nil) != nil ? "Linked from Stats" : "Optional · In Settings → Stats",
                               isDone: ((try? environment.common.activity.kechimochiURL()) ?? nil) != nil),
        ]
    }
}

/// Step 2: Kavita's address and auth key, tested inline.
struct YomuServerStep: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(SetupFlow.self) private var flow
    @State private var model: KavitaSettingsModel?
    @State private var found: String?

    var body: some View {
        if let model {
            @Bindable var model = model
            let connected = model.isConfigured && model.status != .working && !isFailed(model.status)
            SetupPage(step: .server, systemImage: "server.rack", title: "Connect Kavita",
                      subtitle: "Yomu streams your manga and books from your Kavita server.",
                      buttonTitle: connected ? "Continue" : "Connect", canContinue: connected || model.canTest,
                      action: {
                          if connected { flow.advance(from: .server) } else { Task { await connect(model) } }
                      }) {
                SetupCard {
                    TextField("Server URL", text: $model.urlText, prompt: Text(verbatim: "https://kavita.example.ts.net"))
                        .urlEntry()
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .accessibilityIdentifier("setup.server.url")
                    Divider().padding(.leading, 16)
                    SecureField("Auth Key", text: $model.authKey)
                        .credentialEntry()
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .accessibilityIdentifier("setup.server.key")
                }
                Text("In Kavita, open User Settings → Auth Keys and create a key.")
                    .font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                status(model)
            }
            .onChange(of: model.urlText) { found = nil }
            .onChange(of: model.authKey) { found = nil }
        } else {
            Color.clear.onAppear {
                model = KavitaSettingsModel(environment: environment.common)
            }
        }
    }

    @ViewBuilder private func status(_ model: KavitaSettingsModel) -> some View {
        if let found, case .ok = model.status {
            Label(found, systemImage: "checkmark").foregroundStyle(.green).frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("setup.server.status")
        } else if model.isConfigured, model.status == .idle {
            Label("Connected · \(environment.serverAccounts[.kavita]?.hostAndAccount ?? "Kavita")", systemImage: "checkmark")
                .foregroundStyle(.green).frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("setup.server.status")
        } else {
            ConnectionStatusView(status: model.status).frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("setup.server.status")
        }
    }

    private func isFailed(_ status: ConnectionStatus) -> Bool {
        if case .failed = status { true } else { false }
    }

    private func connect(_ model: KavitaSettingsModel) async {
        await model.testAndSave()
        guard case .ok = model.status, let client = environment.kavitaClient() else { return }
        let libraries = ((try? await environment.kavitaLibrary.refreshLibraries(using: client)) ?? []).filter(LibraryModel.readable)
        found = "Connected · Kavita · \(libraries.count == 1 ? "1 library" : "\(libraries.count) libraries") found"
    }
}

/// Step 3: which Kavita libraries show.
struct YomuLibrariesStep: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(SetupFlow.self) private var flow
    @State private var libraries: [KavitaLibrary]?
    @State private var problem: String?

    var body: some View {
        SetupLibrariesStep(
            libraries: libraries?.map { SetupLibrary(id: String($0.id), name: $0.name, detail: Self.kind($0)) },
            problem: problem,
            isShown: { id in Int(id).map { !environment.hiddenLibraries.contains($0) } ?? true },
            setShown: { id, shown in
                if let id = Int(id) { try? environment.libraryVisibility.setHidden(id, hidden: !shown) }
            })
            .task { await load() }
    }

    private static func kind(_ library: KavitaLibrary) -> String {
        library.isBookLibrary ? "Books" : "Manga and comics"
    }

    private func load() async {
        guard let client = environment.kavitaClient() else { problem = "Kavita isn't connected."; return }
        do {
            let all = try await environment.kavitaLibrary.refreshLibraries(using: client).filter(LibraryModel.readable)
            flow.guessLibrariesOnce {
                for library in all {
                    try? environment.libraryVisibility.setHidden(library.id, hidden: !LibraryGuess.isJapanese(library.name))
                }
            }
            libraries = all
        } catch {
            problem = error.localizedDescription
        }
    }
}

/// Step 8: Yomu's optional extras.
struct YomuSetupExtras: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        SetupExtraRow("Manga Text Recognition", detail: "Read speech bubbles on this device · \(OCRStorage.size)",
                      isDone: environment.ocrModels.state == .installed) {
            OCRSettingsView()
        }
        Divider().padding(.leading, 16)
        SetupExtraRow("Read-Along", detail: "Play a matching audiobook with the text (Audiobookshelf and Kaku)",
                      isDone: environment.serverAccounts[.audiobookshelf] != nil) {
            ReadAlongSettingsView()
        }
        Divider().padding(.leading, 16)
        SetupExtraRow("kechimochi", detail: "Your immersion log, linked from Stats",
                      isDone: ((try? environment.common.activity.kechimochiURL()) ?? nil) != nil) {
            Form { StatsSettingsSection() }.formStyle(.grouped).navigationTitle("kechimochi")
        }
    }
}

private enum OCRStorage {
    static var size: String { Int64(OCR.OCRModelStore.totalBytes).storageText }
}
