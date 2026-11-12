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

/// The queue row for Settings: pending and failed counts, opening the queue.
public struct QueueRow: View {
    @Environment(CommonEnvironment.self) private var environment

    public init() {}

    public var body: some View {
        NavigationLink {
            OutboxView()
        } label: {
            LabeledContent("Queue") {
                Text(description)
            }
        }
    }

    private var description: String {
        let summary = environment.outboxSummary
        if summary.pending == 0 && summary.failed == 0 { return "Up to date" }
        var parts = ["\(summary.pending) pending"]
        if summary.failed > 0 { parts.append("\(summary.failed) failed") }
        return parts.joined(separator: ", ")
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
