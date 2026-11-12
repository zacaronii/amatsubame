import AppCommon
import SwiftUI

struct KavitaSettingsView: View {
    @State private var model: KavitaSettingsModel

    init(environment: CommonEnvironment) {
        _model = State(initialValue: KavitaSettingsModel(environment: environment))
    }

    var body: some View {
        Form {
            Section {
                TextField("Server URL", text: $model.urlText, prompt: Text(verbatim: "https://kavita.example.ts.net"))
                    .urlEntry()
                SecureField("Auth Key", text: $model.authKey)
                    .credentialEntry()
            } footer: {
                Text("Create an auth key in Kavita under User Settings → Auth Keys.")
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
        .navigationTitle("Kavita")
    }
}

