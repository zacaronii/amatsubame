import AppCommon
import BrowserKit
import Core
import SwiftUI

/// Hiku: the container app for the Safari extension of the same name. With the
/// App Group (paid developer membership) it holds the extension's setup: dictionaries, audio
/// sources and AnkiConnect, shared with Yomu, Miru and Kiku or its own. Without it, the
/// extension keeps its own built-in dictionaries and this app only explains how to turn it on.
@main
struct BrowserApp: App {
    @State private var environment = BrowserApp.makeEnvironment()

    var body: some Scene {
        WindowGroup {
            SetupView(isShared: BrowserStorage.location().isShared)
                .environment(environment)
                .task { await environment.start() }
        }
    }

    /// The same storage and setup the extension opens.
    static func makeEnvironment() -> CommonEnvironment {
        BrowserEnvironment.make()
    }
}

struct SetupView: View {
    @Environment(CommonEnvironment.self) private var environment
    @Environment(\.scenePhase) private var scenePhase
    @State private var extensionState = ExtensionState()
    let isShared: Bool

    var body: some View {
        NavigationStack {
            Form {
                if let error = environment.startupError {
                    Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
                }
                ExtensionStatusSection(model: extensionState)
                SafariSection()
                if isShared {
                    LookupAndMiningSection {
                        AnkiSettingsPage(environment: environment)
                    }
                    Section {
                        NavigationLink {
                            Form { SetupSharingSection() }
                                .formStyle(.grouped)
                                .navigationTitle("Setup")
                        } label: {
                            SettingsRowLabel("Setup", subtitle: environment.setupMode != .shared ? "Hiku's own"
                                                : environment.appsSharingSetup.isEmpty ? "Shared" : "Shared with \(environment.appsSharingSetup.formatted(.list(type: .and)))",
                                             systemImage: "square.on.square", color: .gray)
                        }
                        NavigationLink {
                            AboutView()
                        } label: {
                            SettingsRowLabel("About", value: "\(CommonEnvironment.appVersion) (\(CommonEnvironment.buildNumber))",
                                             systemImage: "info", color: .blue)
                        }
                    }
                } else {
                    Section {
                        Text("The extension has its own built-in dictionaries for now. Choosing dictionaries and AnkiConnect here, shared with Yomu and Miru, needs the paid developer account.")
                            .foregroundStyle(.secondary)
                    }
                    Section {
                        LabeledContent("Version", value: "\(CommonEnvironment.appVersion) (\(CommonEnvironment.buildNumber))")
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Hiku")
            .navigationDestination(for: ServerKind.self) { _ in AnkiSettingsPage(environment: environment) }
            .task { await extensionState.refresh() }
            .onChange(of: scenePhase) { _, phase in
                // Back from Safari's settings.
                if phase == .active { Task { await extensionState.refresh() } }
            }
        }
    }
}
