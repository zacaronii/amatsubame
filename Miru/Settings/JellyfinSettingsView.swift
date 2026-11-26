import AppCommon
import SwiftUI

struct JellyfinSettingsView: View {
    @State private var model: JellyfinSettingsModel

    init(environment: CommonEnvironment) {
        _model = State(initialValue: JellyfinSettingsModel(environment: environment))
    }

    var body: some View {
        Form {
            if model.isDemo {
                DemoServerSection {
                    Task { await model.signOut() }
                    model.isDemo = false
                    model.urlText = ""
                }
            }
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
                    ConnectionTestRow(status: model.status, disabled: model.status == .working) { Task { await model.testConnection() } }
                    ConfirmedRemoveButton.signOut("Jellyfin") { Task { await model.signOut() } }
                } else {
                    Button("Sign In") { Task { await model.signIn() } }
                        .disabled(!model.canSignIn)
                        .textButtonTint()
                    ConnectionTestRow(status: model.status, disabled: model.urlText.isEmpty || model.status == .working) {
                        Task { await model.testConnection() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Jellyfin")
    }
}

