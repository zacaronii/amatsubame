import AppCommon
import SafariServices
import SwiftUI

/// Whether Hiku's Safari extension is turned on, where the system says (iOS 26.2 and later, and
/// the Mac), and a way to open its settings.
@MainActor @Observable
final class ExtensionState {
    static let identifier = "com.amatsubame.hiku.extension"

    enum State: Equatable {
        /// This iOS doesn't say: the steps are all there is.
        case unknown
        case checking
        case on
        case off
    }

    private(set) var state: State = .checking

    /// Whether the system can open the extension's settings directly.
    var canOpenSettings: Bool {
        #if os(iOS)
        if #available(iOS 26.2, *) { return true }
        return false
        #else
        return true
        #endif
    }

    func refresh() async {
        #if os(iOS)
        if #available(iOS 26.2, *) {
            let extensionState = try? await SFSafariExtensionManager.stateOfExtension(withIdentifier: Self.identifier)
            state = extensionState.map { $0.isEnabled ? .on : .off } ?? .unknown
        } else {
            state = .unknown
        }
        #else
        let enabled = await withCheckedContinuation { continuation in
            SFSafariExtensionManager.getStateOfSafariExtension(withIdentifier: Self.identifier) { state, _ in
                continuation.resume(returning: state?.isEnabled)
            }
        }
        state = enabled.map { $0 ? .on : .off } ?? .unknown
        #endif
    }

    func openSettings() {
        #if os(iOS)
        if #available(iOS 26.2, *) {
            SFSafariSettings.openExtensionsSettings(forIdentifiers: [Self.identifier]) { _ in }
        } else if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
        #else
        SFSafariApplication.showPreferencesForExtension(withIdentifier: Self.identifier) { _ in }
        #endif
    }
}

/// The top of Hiku's screen: on, off, or (where the system doesn't say) what it does.
struct ExtensionStatusSection: View {
    let model: ExtensionState

    var body: some View {
        Section {
            HStack(spacing: 12) {
                SettingsIcon("safari", color: .blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                switch model.state {
                case .on: Image(systemName: "checkmark").foregroundStyle(.green).accessibilityLabel("On")
                case .off: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange).accessibilityLabel("Off")
                case .checking: ProgressView()
                case .unknown: EmptyView()
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("hiku.extensionState")
            if model.canOpenSettings, model.state != .on {
                Button("Open Safari Settings", systemImage: "gear") { model.openSettings() }
                    .accessibilityIdentifier("hiku.openSettings")
            }
        }
    }

    private var title: String {
        switch model.state {
        case .on: "Safari extension is on"
        case .off: "Safari extension is off"
        case .checking: "Checking Safari…"
        case .unknown: "Look words up in Safari"
        }
    }

    private var subtitle: String {
        switch model.state {
        case .on: "Tap Japanese text on a page to look it up."
        case .off: "Turn it on in Safari's settings to tap words on web pages."
        case .checking: " "
        case .unknown: "Turn it on in Safari's settings, then tap Japanese text."
        }
    }
}

/// How to turn the extension on, and how to use it.
struct ExtensionSteps: View {
    var body: some View {
        #if os(iOS)
        step(1, "Open the Settings app, then Apps → Safari → Extensions.")
        step(2, "Tap Hiku and turn it on.")
        step(3, "Under Permissions, allow it on all websites (or the ones you read).")
        #else
        step(1, "Open Safari → Settings → Extensions.")
        step(2, "Turn on Hiku and allow it on the websites you read.")
        #endif
    }

    static let usage = "Tap Japanese text on a page to look it up. The puzzle-piece menu in Safari's address bar turns tap-to-look-up on or off for a site."

    private func step(_ number: Int, _ text: String) -> some View {
        Label(text, systemImage: "\(number).circle")
    }
}

/// Hiku ▸ Safari: the steps, and how it's used.
struct SafariSection: View {
    var body: some View {
        Section("Safari") {
            NavigationLink {
                Form { Section { ExtensionSteps() } }
                    .formStyle(.grouped)
                    .navigationTitle("How to Turn It On")
            } label: {
                SettingsRowLabel("How to Turn It On", subtitle: Self.path, systemImage: "info", color: .blue)
            }
            .accessibilityIdentifier("hiku.howTo")
            NavigationLink {
                Form { Section { Text(ExtensionSteps.usage) } }
                    .formStyle(.grouped)
                    .navigationTitle("Use It in Safari")
            } label: {
                SettingsRowLabel("Use It in Safari", subtitle: ExtensionSteps.usage, systemImage: "safari", color: .blue)
            }
        }
    }

    static var path: String {
        #if os(iOS)
        "Settings → Apps → Safari → Extensions"
        #else
        "Safari → Settings → Extensions"
        #endif
    }
}
