import Core
import SwiftUI

/// Settings → "Share Setup with My Other Apps": dictionaries, audio sources and AnkiConnect
/// shared with Yomu, Miru, Kiku and Hiku through the App Group. Hidden without it.
public struct SetupSharingSection: View {
    @Environment(CommonEnvironment.self) private var environment
    @State private var confirmsJoin = false
    @State private var error: String?

    public init() {}

    public var body: some View {
        if let mode = environment.setupMode {
            Section {
                if environment.setupNeedsChoice {
                    Text("Your other Japanese apps already share a setup, and this app has its own. Which should it use?")
                    Button("Use the Shared Setup") { environment.chooseSharedSetup(true) }
                        .accessibilityIdentifier("setup.useShared")
                    Button("Keep This App\u{2019}s Own") { environment.chooseSharedSetup(false) }
                        .accessibilityIdentifier("setup.keepOwn")
                } else {
                    Toggle("Share Setup with My Other Apps", isOn: Binding(
                        get: { (mode == .shared) != environment.setupSwitchPending },
                        set: { on in
                            if on, (try? environment.setupSharing.map { try !SharedSetup.isEmpty($0.sharedDatabase) }) == true {
                                confirmsJoin = true
                            } else {
                                apply(on)
                            }
                        }))
                        .accessibilityIdentifier("setup.share")
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
            } header: {
                Text("Setup")
            } footer: {
                if environment.setupSwitchPending {
                    Text("Close and reopen the app to switch.")
                } else {
                    Text("Dictionaries, audio sources and AnkiConnect are the same in Yomu, Miru, Kiku and Hiku, and a change in one shows in all. Off: this app keeps its own copy.")
                }
            }
            .confirmationDialog("Use the shared setup?", isPresented: $confirmsJoin, titleVisibility: .visible) {
                Button("Use the Shared Setup") { apply(true) }
            } message: {
                Text("This app\u{2019}s own dictionaries and AnkiConnect settings are replaced by the ones your other apps share.")
            }
        }
    }

    private func apply(_ on: Bool) {
        do {
            try environment.setSharingSetup(on)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
