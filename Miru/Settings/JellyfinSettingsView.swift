import AppCommon
import SwiftUI

struct JellyfinSettingsView: View {
    @State private var model: JellyfinSettingsModel

    init(environment: CommonEnvironment) {
        _model = State(initialValue: JellyfinSettingsModel(environment: environment))
    }

    var body: some View {
        Form {
            Section {
                TextField("Server URL", text: $model.urlText, prompt: Text(verbatim: "https://jellyfin.example.ts.net"))
                    .urlEntry()
                    .disabled(model.isSignedIn)
            }
            Section {
                TextField("Username", text: $model.username)
                    .credentialEntry()
                    .textContentType(.username)
                    .disabled(model.isSignedIn)
                if !model.isSignedIn {
                    SecureField("Password", text: $model.password)
                        .textContentType(.password)
                        .onSubmit { Task { await model.signIn() } }
                }
            } footer: {
                Text("The password is only used to sign in. The app keeps the access token in the Keychain.")
            }
            Section {
                if model.isSignedIn {
                    Button("Test Connection") { Task { await model.testConnection() } }
                        .disabled(model.status == .working)
                    Button("Sign Out", role: .destructive) { Task { await model.signOut() } }
                } else {
                    Button("Sign In") { Task { await model.signIn() } }
                        .disabled(!model.canSignIn)
                    Button("Test Connection") { Task { await model.testConnection() } }
                        .disabled(model.urlText.isEmpty || model.status == .working)
                }
                ConnectionStatusView(status: model.status)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Jellyfin")
    }
}

