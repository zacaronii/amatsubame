import AudiobookshelfKit
import SwiftUI

/// Signing in to Audiobookshelf (Kiku, and Yomu for read-along).
public struct AudiobookshelfSettingsView: View {
    @State private var model: AudiobookshelfSettingsModel
    private let appName: String

    public init(environment: CommonEnvironment, tokens: AudiobookshelfTokens, appName: String) {
        _model = State(initialValue: AudiobookshelfSettingsModel(environment: environment, tokens: tokens))
        self.appName = appName
    }

    public var body: some View {
        Form {
            if model.isDemo {
                DemoServerSection {
                    model.signOut()
                    model.isDemo = false
                    model.urlText = ""
                }
            }
            Section {
                TextField("Server URL", text: $model.urlText, prompt: Text(verbatim: "https://audiobookshelf.example.ts.net"))
                    .urlEntry()
                    .disabled(model.isSignedIn)
            }
            if !model.isSignedIn {
                Section {
                    Picker("Sign In With", selection: $model.method) {
                        Text("Password").tag(AudiobookshelfSettingsModel.Method.password)
                        Text("API Key").tag(AudiobookshelfSettingsModel.Method.apiKey)
                    }
                    .pickerStyle(.segmented)
                    switch model.method {
                    case .password:
                        TextField("Username", text: $model.username)
                            .credentialEntry()
                            .textContentType(.username)
                        SecureField("Password", text: $model.password)
                            .textContentType(.password)
                            .onSubmit { Task { await model.signIn() } }
                    case .apiKey:
                        SecureField("API Key", text: $model.apiKey)
                            .credentialEntry()
                            .onSubmit { Task { await model.signIn() } }
                    }
                } footer: {
                    Text(model.method == .password
                         ? "The password is only used to sign in. \(appName) keeps the access token in the Keychain."
                         : "Make one in Audiobookshelf under Settings ▸ API Keys. \(appName) keeps it in the Keychain.")
                }
            } else {
                Section("Signed In") {
                    LabeledContent("User", value: model.username)
                }
            }
            Section {
                if model.isSignedIn {
                    ConnectionTestRow(status: model.status, disabled: model.status == .working) { Task { await model.testConnection() } }
                    ConfirmedRemoveButton.signOut("Audiobookshelf") { model.signOut() }
                } else {
                    Button("Sign In") { Task { await model.signIn() } }
                        .disabled(!model.canSignIn)
                        .accessibilityIdentifier("audiobookshelf.signIn")
                    ConnectionTestRow(status: model.status, disabled: model.urlText.isEmpty || model.status == .working) {
                        Task { await model.testConnection() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Audiobookshelf")
    }
}

/// Settings ▸ Kaku: what the server is doing, its libraries, and a link to its address and token
/// (`KakuConnectionView`). Until Kaku is set up, the address and token themselves.
public struct KakuSettingsView: View {
    @State private var connection: KakuSettingsModel
    @State private var server: KakuServerModel
    private let environment: CommonEnvironment

    public init(environment: CommonEnvironment) {
        _connection = State(initialValue: KakuSettingsModel(environment: environment))
        _server = State(initialValue: KakuServerModel(common: environment))
        self.environment = environment
    }

    public var body: some View {
        let account = environment.serverAccounts[.kaku]
        Form {
            if let account {
                KakuServerSections(model: server)
                Section {
                    NavigationLink {
                        KakuConnectionView(environment: environment)
                    } label: {
                        LabeledContent("Connection", value: account.baseURL.host() ?? account.baseURL.absoluteString)
                    }
                    .accessibilityIdentifier("kaku.connection")
                } footer: {
                    Text("Kaku's address and token.")
                }
            } else {
                KakuConnectionSections(model: connection)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Kaku")
        // On the form, not a row: rows off screen (or not there yet) wouldn't run it.
        .task(id: account?.baseURL) {
            server.clear()
            if account != nil {
                await server.follow()
            } else {
                // Removed (in Connection): nothing of the old address and token stays in the form.
                connection = KakuSettingsModel(environment: environment)
            }
        }
    }
}

/// Kaku's address and token, with Test Connection and Remove Server: setup's Kaku step, and
/// Settings ▸ Kaku ▸ Connection.
public struct KakuConnectionView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: KakuSettingsModel

    public init(environment: CommonEnvironment) {
        _model = State(initialValue: KakuSettingsModel(environment: environment))
    }

    public var body: some View {
        Form {
            KakuConnectionSections(model: model) { dismiss() }
        }
        .formStyle(.grouped)
        .navigationTitle(model.isConfigured ? "Connection" : "Kaku")
    }
}

struct KakuConnectionSections: View {
    @Bindable var model: KakuSettingsModel
    /// After Remove Server.
    var removed: () -> Void = {}

    var body: some View {
        Section {
            TextField("Server URL", text: $model.urlText, prompt: Text(verbatim: "https://kaku.example.ts.net"))
                .urlEntry()
                .accessibilityIdentifier("kaku.url")
            SecureField("Token", text: $model.token)
                .credentialEntry()
                .accessibilityIdentifier("kaku.token")
        } footer: {
            Text("Kaku transcribes your Audiobookshelf podcasts and audiobooks, and Jellyfin episodes Jimaku has no subtitles for. The token is KAKU_API_TOKEN from its server settings.")
        }
        Section {
            ConnectionTestRow(status: model.status, disabled: !model.canTest, identifier: "kaku.test") { Task { await model.testAndSave() } }
        }
        if model.isConfigured {
            Section {
                ConfirmedRemoveButton.removeServer("Kaku") {
                    model.remove()
                    removed()
                }
            }
        }
    }
}
