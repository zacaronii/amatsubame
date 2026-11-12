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
                    Button("Test Connection") { Task { await model.testConnection() } }
                        .disabled(model.status == .working)
                    Button("Sign Out", role: .destructive) { model.signOut() }
                } else {
                    Button("Sign In") { Task { await model.signIn() } }
                        .disabled(!model.canSignIn)
                        .accessibilityIdentifier("audiobookshelf.signIn")
                    Button("Test Connection") { Task { await model.testConnection() } }
                        .disabled(model.urlText.isEmpty || model.status == .working)
                }
                ConnectionStatusView(status: model.status)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Audiobookshelf")
    }
}

/// Kaku's URL and token (Kiku, and Yomu for read-along).
public struct KakuSettingsView: View {
    @State private var model: KakuSettingsModel

    public init(environment: CommonEnvironment) {
        _model = State(initialValue: KakuSettingsModel(environment: environment))
    }

    public var body: some View {
        Form {
            Section {
                TextField("Server URL", text: $model.urlText, prompt: Text(verbatim: "https://kaku.example.ts.net"))
                    .urlEntry()
                SecureField("Token", text: $model.token)
                    .credentialEntry()
            } footer: {
                Text("Kaku transcribes your Audiobookshelf podcasts and audiobooks, and Jellyfin episodes Jimaku has no subtitles for. The token is KAKU_API_TOKEN from its server settings.")
            }
            Section {
                Button("Test Connection") { Task { await model.testAndSave() } }
                    .disabled(!model.canTest)
                ConnectionStatusView(status: model.status)
            }
            if model.isConfigured {
                Section {
                    Button("Remove Server", role: .destructive) { model.remove() }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Kaku")
    }
}
