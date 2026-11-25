import Core
import SwiftUI

public struct ConnectionStatusView: View {
    let status: ConnectionStatus

    public init(status: ConnectionStatus) {
        self.status = status
    }

    public var body: some View {
        switch status {
        case .idle:
            EmptyView()
        case .working:
            HStack {
                ProgressView()
                Text("Connecting…").foregroundStyle(.secondary)
            }
        case .ok(let message):
            Label(message, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
        }
    }
}

/// Test Connection and what it found. On the Mac one row, Status, with the button on its
/// right; on iPhone and iPad the button with the result under it.
public struct ConnectionTestRow: View {
    let status: ConnectionStatus
    let disabled: Bool
    let identifier: String?
    let action: () -> Void

    public init(status: ConnectionStatus, disabled: Bool = false, identifier: String? = nil, action: @escaping () -> Void) {
        self.status = status
        self.disabled = disabled
        self.identifier = identifier
        self.action = action
    }

    public var body: some View {
        #if os(macOS)
        LabeledContent("Status") {
            HStack(spacing: 10) {
                if status == .idle {
                    Text("Not tested").foregroundStyle(.secondary)
                } else {
                    ConnectionStatusView(status: status)
                }
                button
            }
        }
        #else
        button
        ConnectionStatusView(status: status)
        #endif
    }

    @ViewBuilder private var button: some View {
        let button = Button("Test Connection", action: action).disabled(disabled)
        if let identifier {
            button.accessibilityIdentifier(identifier)
        } else {
            button
        }
    }
}

/// Sign Out and Remove Server. On the Mac it asks first; on iPhone and iPad it acts at once,
/// as it always has.
public struct ConfirmedRemoveButton: View {
    let title: String
    let question: String
    let message: String
    let action: () -> Void
    @State private var asking = false

    public init(_ title: String, question: String, message: String, action: @escaping () -> Void) {
        self.title = title
        self.question = question
        self.message = message
        self.action = action
    }

    public var body: some View {
        #if os(macOS)
        Button("\(title)…", role: .destructive) { asking = true }
            .confirmationDialog(question, isPresented: $asking) {
                Button(title, role: .destructive, action: action)
            } message: {
                Text(message)
            }
        #else
        Button(title, role: .destructive, action: action)
        #endif
    }
}

public extension ConfirmedRemoveButton {
    /// Remove Server for `name` (Kavita, Kaku, AnkiConnect).
    static func removeServer(_ name: String, action: @escaping () -> Void) -> ConfirmedRemoveButton {
        ConfirmedRemoveButton("Remove Server", question: "Remove \(name)?",
                              message: "Its address and key are forgotten here. Nothing changes on the server, and you can add it again.",
                              action: action)
    }

    /// Sign Out of `name` (Jellyfin, Audiobookshelf).
    static func signOut(_ name: String, action: @escaping () -> Void) -> ConfirmedRemoveButton {
        ConfirmedRemoveButton("Sign Out", question: "Sign out of \(name)?",
                              message: "You'll need to sign in again to use it.", action: action)
    }
}

public extension View {
    func urlEntry() -> some View {
        #if os(iOS)
        self.keyboardType(.URL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .textContentType(.URL)
        #else
        self.autocorrectionDisabled()
        #endif
    }

    func credentialEntry() -> some View {
        #if os(iOS)
        self.textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        #else
        self.autocorrectionDisabled()
        #endif
    }
}

/// A server in a Settings list: name, and whether it's set up and reachable.
public struct ServerRow: View {
    let kind: ServerKind
    let account: ServerAccount?

    public init(kind: ServerKind, account: ServerAccount?) {
        self.kind = kind
        self.account = account
    }

    public var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(dotColor)
                .frame(width: 10, height: 10)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.displayName)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var dotColor: Color {
        account?.dotColor ?? .secondary.opacity(0.4)
    }

    /// Where it is and who's signed in; the version is on the server's own page.
    private var subtitle: String {
        account?.hostAndAccount ?? "Not set up"
    }
}

public extension ServerKind {
    var displayName: String {
        switch self {
        case .kavita: "Kavita"
        case .jellyfin: "Jellyfin"
        case .anki: "AnkiConnect"
        case .audiobookshelf: "Audiobookshelf"
        case .kaku: "Kaku"
        }
    }
}

/// A server page signed in to the public demo: what it is, and the way to your own server
/// (signing out of the demo, which discards what it held on this device).
public struct DemoServerSection: View {
    let useOwnServer: () -> Void

    public init(useOwnServer: @escaping () -> Void) {
        self.useOwnServer = useOwnServer
    }

    public var body: some View {
        Section {
            Label("Demo server", systemImage: "sparkles")
                .accessibilityIdentifier("server.demo")
            Button("Use My Own Server…", action: useOwnServer)
                .accessibilityIdentifier("server.demo.ownServer")
        } footer: {
            Text("Nothing you do is saved to it. Your places and marks stay on this \(StorageSummary.deviceName) until you leave the demo.")
        }
    }
}
