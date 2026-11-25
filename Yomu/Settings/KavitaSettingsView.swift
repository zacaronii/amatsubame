import AppCommon
import SwiftUI

struct KavitaSettingsView: View {
    @State private var model: KavitaSettingsModel

    init(environment: CommonEnvironment) {
        _model = State(initialValue: KavitaSettingsModel(environment: environment))
    }

    var body: some View {
        Form {
            if model.isDemo {
                DemoServerSection {
                    model.remove()
                    model.isDemo = false
                }
            }
            Section {
                TextField("Server URL", text: $model.urlText, prompt: Text(verbatim: "https://kavita.example.ts.net"))
                    .urlEntry()
                SecureField("Auth Key", text: $model.authKey)
                    .credentialEntry()
            } footer: {
                Text("Create an auth key in Kavita under User Settings → Auth Keys.")
            }
            Section {
                ConnectionTestRow(status: model.status, disabled: !model.canTest) { Task { await model.testAndSave() } }
            }
            if model.isConfigured {
                Section {
                    ConfirmedRemoveButton.removeServer("Kavita") { model.remove() }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Kavita")
    }
}

